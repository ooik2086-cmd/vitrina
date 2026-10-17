"""Chat between buyer and seller, reviews of sellers, and in-app notifications."""
from __future__ import annotations

import re
from datetime import timedelta

from fastapi import APIRouter, Depends, File, Form, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus

from . import services
from .deps import current_user, get_db, get_storage, now_utc
from .errors import ApiError
from .storage import MAX_UPLOAD_BYTES, LocalStorage, normalize_image
from .models import Conversation, Listing, Message, Notification, Order, Review, User

router = APIRouter(prefix="/api/v1")

MESSAGES_PER_MINUTE = 20
# Phone numbers (7-12 digits with separators), links and messenger handles.
CONTACT_RE = re.compile(r"(\+?\d[\d\s\-()]{8,}\d)|(https?://|www\.)|(\b(whats\s?app|telegram|t\.me|ватсап|телеграм)\b)",
                        re.IGNORECASE)


class ConversationIn(BaseModel):
    listing_id: int


class MessageIn(BaseModel):
    body: str = Field(min_length=1, max_length=2000)


class ReviewIn(BaseModel):
    rating: int = Field(ge=1, le=5)
    text: str | None = Field(default=None, max_length=1000)


class ReplyIn(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


def seller_rating(db: Session, seller_id: int) -> dict:
    avg, count = db.execute(select(func.avg(Review.rating), func.count(Review.id))
                            .where(Review.seller_id == seller_id)).one()
    return {"rating": round(float(avg), 1) if avg is not None else None, "reviews": int(count)}


# ---------------------------------------------------------------- chat
def conversation_for(db: Session, conversation_id: int, user: User) -> Conversation:
    conv = db.get(Conversation, conversation_id)
    if conv is None or user.id not in (conv.buyer_id, conv.seller_id):
        raise ApiError(404, "not_found")
    return conv


def message_out(m: Message) -> dict:
    return {"id": m.id, "sender_id": m.sender_id, "body": m.body, "photo_url": m.photo_url,
            "contact_warning": m.contact_warning,
            "created_at": services.aware(m.created_at).isoformat()}


def conversation_out(db: Session, conv: Conversation, user: User) -> dict:
    listing = db.get(Listing, conv.listing_id)
    me_buyer = user.id == conv.buyer_id
    other = db.get(User, conv.seller_id if me_buyer else conv.buyer_id)
    last_read = conv.buyer_last_read_id if me_buyer else conv.seller_last_read_id
    last = db.scalar(select(Message).where(Message.conversation_id == conv.id).order_by(Message.id.desc()).limit(1))
    unread = db.scalar(select(func.count(Message.id)).where(
        Message.conversation_id == conv.id, Message.id > last_read, Message.sender_id != user.id))
    cover = next((m.processed_url or m.original_url for m in listing.media if m.angle != "frame"), None)
    return {
        "id": conv.id, "listing_id": listing.id, "listing_title": listing.title, "listing_cover": cover,
        "price_tiyn": listing.price_tiyn, "role": "buyer" if me_buyer else "seller",
        # Names only, never phone numbers.
        "other_name": (other.shop_name if me_buyer else other.display_name) or ("Сатушы" if me_buyer else "Сатып алушы"),
        "last_message": message_out(last) if last else None, "unread": int(unread or 0),
    }


@router.post("/conversations", status_code=201)
def open_conversation(body: ConversationIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, body.listing_id)
    if listing is None or listing.status not in ("published", "sold"):
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    conv = db.scalar(select(Conversation).where(Conversation.listing_id == listing.id,
                                                Conversation.buyer_id == user.id))
    if conv is None:
        conv = Conversation(listing_id=listing.id, buyer_id=user.id, seller_id=listing.seller_id)
        db.add(conv)
        db.commit()
    return conversation_out(db, conv, user)


@router.get("/conversations")
def list_conversations(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Conversation).where(or_(Conversation.buyer_id == user.id, Conversation.seller_id == user.id))
                      .order_by(Conversation.last_message_at.desc()).limit(100)).all()
    return {"items": [conversation_out(db, c, user) for c in rows]}


@router.get("/conversations/{conversation_id}/messages")
def list_messages(conversation_id: int, after_id: int = 0, user: User = Depends(current_user),
                  db: Session = Depends(get_db)):
    conv = conversation_for(db, conversation_id, user)
    rows = db.scalars(select(Message).where(Message.conversation_id == conv.id, Message.id > after_id)
                      .order_by(Message.id).limit(200)).all()
    if rows:  # reading the thread marks it read
        if user.id == conv.buyer_id:
            conv.buyer_last_read_id = max(conv.buyer_last_read_id, rows[-1].id)
        else:
            conv.seller_last_read_id = max(conv.seller_last_read_id, rows[-1].id)
        db.commit()
    return {"conversation": conversation_out(db, conv, user), "items": [message_out(m) for m in rows]}


@router.post("/conversations/{conversation_id}/messages", status_code=201)
def send_message(conversation_id: int, body: MessageIn, user: User = Depends(current_user),
                 db: Session = Depends(get_db)):
    conv = conversation_for(db, conversation_id, user)
    text = body.body.strip()
    if not text:
        raise ApiError(422, "validation", "empty message")
    return post_message(db, conv, user, text, None)


@router.post("/conversations/{conversation_id}/photos", status_code=201)
async def send_photo(conversation_id: int, file: UploadFile = File(...), caption: str = Form("", max_length=2000),
                     user: User = Depends(current_user), db: Session = Depends(get_db),
                     storage: LocalStorage = Depends(get_storage)):
    """A photo in the chat, e.g. a close-up the buyer asked for. Cleaned of metadata like any upload."""
    conv = conversation_for(db, conversation_id, user)
    check_rate(db, user)
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    url = storage.put(normalize_image(data), owner_id=user.id)
    return post_message(db, conv, user, caption.strip(), url)


def check_rate(db: Session, user: User) -> None:
    recent = db.scalar(select(func.count(Message.id)).where(
        Message.sender_id == user.id, Message.created_at >= now_utc() - timedelta(minutes=1)))
    if recent >= MESSAGES_PER_MINUTE:
        raise ApiError(429, "rate_limited")


def post_message(db: Session, conv: Conversation, user: User, text: str, photo_url: str | None) -> dict:
    check_rate(db, user)
    msg = Message(conversation_id=conv.id, sender_id=user.id, body=text, photo_url=photo_url,
                  contact_warning=bool(CONTACT_RE.search(text)))
    db.add(msg)
    db.flush()
    conv.last_message_at = now_utc()
    if user.id == conv.buyer_id:
        conv.buyer_last_read_id = msg.id
    else:
        conv.seller_last_read_id = msg.id
    other = conv.seller_id if user.id == conv.buyer_id else conv.buyer_id
    preview_kk = text[:120] if text else "📷 Фото"
    preview_ru = text[:120] if text else "📷 Фото"
    services.notify(db, other, "message", f"Жаңа хабарлама: {preview_kk}",
                    f"Новое сообщение: {preview_ru}", conversation_id=conv.id)
    db.commit()
    return message_out(msg)


# ---------------------------------------------------------------- reviews
def review_out(db: Session, r: Review) -> dict:
    buyer = db.get(User, r.buyer_id)
    return {"id": r.id, "order_id": r.order_id, "rating": r.rating, "text": r.text, "seller_reply": r.seller_reply,
            "buyer_name": buyer.display_name or "Сатып алушы", "created_at": services.aware(r.created_at).isoformat()}


@router.post("/orders/{order_id}/review", status_code=201)
def create_review(order_id: int, body: ReviewIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = db.get(Order, order_id)
    if order is None or order.buyer_id != user.id:
        raise ApiError(404, "not_found")
    if order.status != OrderStatus.COMPLETED.value:
        raise ApiError(409, "review_not_allowed", "only completed orders can be reviewed")
    if db.scalar(select(Review).where(Review.order_id == order.id)):
        raise ApiError(409, "already_reviewed")
    review = Review(order_id=order.id, seller_id=order.seller_id, buyer_id=user.id, rating=body.rating,
                    text=(body.text or "").strip() or None)
    db.add(review)
    services.notify(db, order.seller_id, "review", f"Жаңа пікір: {body.rating}/5, тапсырыс №{order.id}.",
                    f"Новый отзыв: {body.rating}/5, заказ №{order.id}.",
                    order_id=order.id)
    db.commit()
    return review_out(db, review)


@router.post("/reviews/{review_id}/reply")
def reply_review(review_id: int, body: ReplyIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    review = db.get(Review, review_id)
    if review is None or review.seller_id != user.id:
        raise ApiError(404, "not_found")
    if review.seller_reply:
        raise ApiError(409, "already_replied")
    review.seller_reply = body.text.strip()
    services.notify(db, review.buyer_id, "review_reply", f"Сатушы пікіріңізге жауап берді: {review.seller_reply[:120]}",
                    f"Продавец ответил на ваш отзыв: {review.seller_reply[:120]}",
                    order_id=review.order_id)
    db.commit()
    return review_out(db, review)


@router.get("/sellers/{seller_id}/reviews")
def seller_reviews(seller_id: int, db: Session = Depends(get_db)):
    seller = db.get(User, seller_id)
    if seller is None or not seller.is_seller:
        raise ApiError(404, "not_found")
    rows = db.scalars(select(Review).where(Review.seller_id == seller_id).order_by(Review.id.desc()).limit(100)).all()
    return {"seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
                       **seller_rating(db, seller.id)},
            "items": [review_out(db, r) for r in rows]}


# ---------------------------------------------------------------- notifications
@router.get("/notifications")
def list_notifications(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Notification).where(Notification.user_id == user.id)
                      .order_by(Notification.id.desc()).limit(100)).all()
    unread = db.scalar(select(func.count(Notification.id)).where(Notification.user_id == user.id,
                                                                 Notification.read.is_(False)))
    return {"unread": int(unread or 0), "items": [
        {"id": n.id, "kind": n.kind, "text": n.text_kk, "text_ru": n.text_ru or n.text_kk, "order_id": n.order_id, "conversation_id": n.conversation_id,
         "read": n.read, "created_at": services.aware(n.created_at).isoformat()} for n in rows]}


@router.post("/notifications/read-all", status_code=204)
def read_all_notifications(user: User = Depends(current_user), db: Session = Depends(get_db)):
    for n in db.scalars(select(Notification).where(Notification.user_id == user.id, Notification.read.is_(False))):
        n.read = True
    db.commit()
