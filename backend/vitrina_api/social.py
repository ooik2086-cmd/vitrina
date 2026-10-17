"""Chat between buyer and seller, reviews of sellers, and in-app notifications."""
from __future__ import annotations

import json
import re
import statistics
from datetime import datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, File, Form, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus

from . import services
from .deps import current_user, get_db, get_storage, now_utc
from .errors import ApiError
from .storage import MAX_UPLOAD_BYTES, Storage, normalize_image
from .models import Block, Conversation, Listing, Message, Notification, Order, Review, User

router = APIRouter(prefix="/api/v1")

MESSAGES_PER_MINUTE = 20
# Phone numbers (7-12 digits with separators), links and messenger handles.
CONTACT_RE = re.compile(r"(\+?\d[\d\s\-()]{8,}\d)|(https?://|www\.)|(\b(whats\s?app|telegram|t\.me|ватсап|телеграм)\b)",
                        re.IGNORECASE)


class ConversationIn(BaseModel):
    listing_id: int


class MessageIn(BaseModel):
    body: str = Field(min_length=1, max_length=2000)


MAX_REVIEW_PHOTOS = 3


class ReviewIn(BaseModel):
    rating: int = Field(ge=1, le=5)
    text: str | None = Field(default=None, max_length=1000)
    photos: list[str] = Field(default_factory=list, max_length=MAX_REVIEW_PHOTOS)
    fit: Literal["small", "true", "large"] | None = None


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
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    conv = db.scalar(select(Conversation).where(Conversation.listing_id == listing.id,
                                                Conversation.buyer_id == user.id))
    if conv is None:
        conv = Conversation(listing_id=listing.id, buyer_id=user.id, seller_id=listing.seller_id)
        db.add(conv)
        db.commit()
    return conversation_out(db, conv, user)


@router.post("/orders/{order_id}/conversation")
def order_conversation(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The chat about an order, from either side, even after the listing sold out or was taken down."""
    order = db.get(Order, order_id)
    if order is None or user.id not in (order.buyer_id, order.seller_id):
        raise ApiError(404, "not_found")
    services.ensure_not_blocked(db, order.buyer_id, order.seller_id)
    conv = db.scalar(select(Conversation).where(Conversation.listing_id == order.listing_id,
                                                Conversation.buyer_id == order.buyer_id))
    if conv is None:
        conv = Conversation(listing_id=order.listing_id, buyer_id=order.buyer_id, seller_id=order.seller_id)
        db.add(conv)
        db.commit()
    return conversation_out(db, conv, user)


@router.get("/conversations")
def list_conversations(user: User = Depends(current_user), db: Session = Depends(get_db)):
    # Threads with someone this user blocked drop out of the list; the blocked side still sees theirs.
    mine = select(Block.blocked_id).where(Block.user_id == user.id)
    rows = db.scalars(select(Conversation).where(
        or_(and_(Conversation.buyer_id == user.id, Conversation.seller_id.not_in(mine)),
            and_(Conversation.seller_id == user.id, Conversation.buyer_id.not_in(mine))))
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
                     storage: Storage = Depends(get_storage)):
    """A photo in the chat, e.g. a close-up the buyer asked for. Cleaned of metadata like any upload."""
    conv = conversation_for(db, conversation_id, user)
    check_rate(db, user)
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    url = storage.put(normalize_image(data), owner_id=user.id)
    return post_message(db, conv, user, caption.strip(), url)


@router.post("/conversations/{conversation_id}/block")
def block_from_chat(conversation_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Blocks the other side of this chat: no more messages, offers, questions or orders between the two."""
    conv = conversation_for(db, conversation_id, user)
    other = conv.seller_id if user.id == conv.buyer_id else conv.buyer_id
    if not db.scalar(select(Block.id).where(Block.user_id == user.id, Block.blocked_id == other)):
        db.add(Block(user_id=user.id, blocked_id=other))
        db.commit()
    return {"blocked": True}


def block_name(db: Session, block: Block) -> str:
    other = db.get(User, block.blocked_id)
    return other.shop_name or other.display_name or "Пайдаланушы"


@router.get("/me/blocks")
def list_blocks(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Block).where(Block.user_id == user.id).order_by(Block.id.desc())).all()
    return {"items": [{"user_id": b.blocked_id, "name": block_name(db, b),
                       "since": services.aware(b.created_at).isoformat()} for b in rows]}


@router.delete("/me/blocks/{user_id}")
def unblock(user_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    block = db.scalar(select(Block).where(Block.user_id == user.id, Block.blocked_id == user_id))
    if block is None:
        raise ApiError(404, "not_found")
    db.delete(block)
    db.commit()
    return {"blocked": False}


def check_rate(db: Session, user: User) -> None:
    recent = db.scalar(select(func.count(Message.id)).where(
        Message.sender_id == user.id, Message.created_at >= now_utc() - timedelta(minutes=1)))
    if recent >= MESSAGES_PER_MINUTE:
        raise ApiError(429, "rate_limited")


def post_message(db: Session, conv: Conversation, user: User, text: str, photo_url: str | None) -> dict:
    services.ensure_not_blocked(db, conv.buyer_id, conv.seller_id)
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
    preview_en = text[:120] if text else "📷 Photo"
    services.notify(db, other, "message", f"Жаңа хабарлама: {preview_kk}",
                    f"Новое сообщение: {preview_ru}", f"New message: {preview_en}", conversation_id=conv.id)
    db.commit()
    return message_out(msg)


# ---------------------------------------------------------------- reviews
REPLY_WINDOW = timedelta(days=30)
REPLY_MIN_SAMPLES = 3
UNANSWERED_AFTER = timedelta(hours=24)  # a question left this long counts as answered in a day, so silence shows


def reply_time(db: Session, seller_id: int) -> dict | None:
    """How fast the seller usually answers a buyer's message: the median wait over the last 30 days.

    A wait starts at the first buyer message after the seller last wrote and ends at the seller's next message.
    """
    now = now_utc()
    rows = db.execute(select(Message.conversation_id, Message.sender_id, Message.created_at).join(
        Conversation, Conversation.id == Message.conversation_id).where(
        Conversation.seller_id == seller_id, Message.created_at >= now - REPLY_WINDOW).order_by(
        Message.conversation_id, Message.id)).all()
    waits: list[float] = []
    waiting_since: dict[int, datetime] = {}
    for conv, sender, at in rows:
        at = services.aware(at)
        if sender != seller_id:
            waiting_since.setdefault(conv, at)
        elif conv in waiting_since:
            waits.append((at - waiting_since.pop(conv)).total_seconds() / 60)
    waits += [UNANSWERED_AFTER.total_seconds() / 60 for since in waiting_since.values()
              if now - since >= UNANSWERED_AFTER]
    if len(waits) < REPLY_MIN_SAMPLES:
        return None
    minutes = statistics.median(waits)
    bucket = "hour" if minutes <= 60 else "hours" if minutes <= 180 else "day" if minutes < 1440 else "days"
    return {"minutes": round(minutes), "bucket": bucket}


FIT_MIN_ANSWERS = 3  # fewer answers than this say more about one foot than about the shoe


def size_fit(db: Session, listing: Listing) -> dict | None:
    """How buyers said the size felt: for every listing of the same model when brand and model are known,
    since the last is the same whoever sells it, otherwise for this listing alone."""
    stmt = select(Review.fit, func.count(Review.id)).join(Order, Order.id == Review.order_id).join(
        Listing, Listing.id == Order.listing_id).where(Review.fit.is_not(None)).group_by(Review.fit)
    if listing.brand and listing.model_name:
        stmt = stmt.where(Listing.brand == listing.brand, Listing.model_name == listing.model_name)
    else:
        stmt = stmt.where(Listing.id == listing.id)
    counts = {"small": 0, "true": 0, "large": 0, **{fit: n for fit, n in db.execute(stmt).all()}}
    answers = sum(counts.values())
    if answers < FIT_MIN_ANSWERS:
        return None
    return {"answers": answers, **counts}


def review_out(db: Session, r: Review) -> dict:
    buyer = db.get(User, r.buyer_id)
    return {"id": r.id, "order_id": r.order_id, "rating": r.rating, "text": r.text, "seller_reply": r.seller_reply,
            "photos": json.loads(r.photos) if r.photos else [], "fit": r.fit,
            "buyer_name": buyer.display_name or "Сатып алушы", "created_at": services.aware(r.created_at).isoformat()}


def reviewable_order(db: Session, order_id: int, user: User) -> Order:
    order = db.get(Order, order_id)
    if order is None or order.buyer_id != user.id:
        raise ApiError(404, "not_found")
    if order.status != OrderStatus.COMPLETED.value:
        raise ApiError(409, "review_not_allowed", "only completed orders can be reviewed")
    if db.scalar(select(Review).where(Review.order_id == order.id)):
        raise ApiError(409, "already_reviewed")
    return order


@router.post("/orders/{order_id}/review/photos", status_code=201)
async def upload_review_photo(order_id: int, file: UploadFile = File(...), user: User = Depends(current_user),
                              db: Session = Depends(get_db), storage: Storage = Depends(get_storage)):
    """A buyer's photo of the pair that arrived, for their review. Cleaned of metadata like any upload."""
    reviewable_order(db, order_id, user)
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    return {"url": storage.put(normalize_image(data), owner_id=user.id)}


@router.post("/orders/{order_id}/review", status_code=201)
def create_review(order_id: int, body: ReviewIn, user: User = Depends(current_user), db: Session = Depends(get_db),
                  storage: Storage = Depends(get_storage)):
    order = reviewable_order(db, order_id, user)
    # Only photos this buyer uploaded here: never a link to someone else's picture or another site.
    own = storage.public_base + f"/{user.id}/"
    if any(not url.startswith(own) for url in body.photos):
        raise ApiError(422, "foreign_media")
    review = Review(order_id=order.id, seller_id=order.seller_id, buyer_id=user.id, rating=body.rating,
                    text=(body.text or "").strip() or None, photos=json.dumps(body.photos) if body.photos else None,
                    fit=body.fit)
    db.add(review)
    services.notify(db, order.seller_id, "review", f"Жаңа пікір: {body.rating}/5, тапсырыс №{order.id}.",
                    f"Новый отзыв: {body.rating}/5, заказ №{order.id}.",
                    f"New review: {body.rating}/5, order No. {order.id}.",
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
                    f"The seller replied to your review: {review.seller_reply[:120]}",
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
        {"id": n.id, "kind": n.kind, "text": n.text_kk, "text_ru": n.text_ru or n.text_kk,
         "text_en": n.text_en or n.text_ru or n.text_kk, "order_id": n.order_id, "conversation_id": n.conversation_id,
         "listing_id": n.listing_id,
         "read": n.read, "created_at": services.aware(n.created_at).isoformat()} for n in rows]}


@router.post("/notifications/read-all", status_code=204)
def read_all_notifications(user: User = Depends(current_user), db: Session = Depends(get_db)):
    for n in db.scalars(select(Notification).where(Notification.user_id == user.id, Notification.read.is_(False))):
        n.read = True
    db.commit()
