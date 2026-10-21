"""Chat between buyer and seller, reviews of sellers, and in-app notifications."""
from __future__ import annotations

import json
import re
import statistics
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, File, Form, Header, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import and_, case, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus

from . import services
from .deps import current_user, get_db, get_storage, now_utc
from .errors import ApiError
from .storage import MAX_UPLOAD_BYTES, Storage, normalize_image
from .models import Block, Conversation, IdempotencyRecord, Listing, Message, Notification, Order, Review, User

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


def preload_conversations(db: Session, convs: list[Conversation], user: User) -> None:
    """Reads what a list of chats shows (listings with their photos, the other people, each chat's last message and
    unread count) in a few queries for the whole list; conversation_out then finds them in db.info. The last message
    and unread count are this user's: a request serves one viewer."""
    from .serializers import BARE, with_covers  # serializers imports this module
    if not convs:
        return
    ids = [c.id for c in convs]
    listings = db.info.setdefault("conv_listing", {})
    listings.update({row.id: row for row in db.scalars(select(Listing).options(*BARE).where(
        Listing.id.in_({c.listing_id for c in convs})))})
    with_covers(db, list(listings.values()))
    people = db.info.setdefault("conv_user", {})
    people.update({row.id: row for row in db.scalars(select(User).where(
        User.id.in_({c.buyer_id for c in convs} | {c.seller_id for c in convs})))})
    newest = select(func.max(Message.id)).where(Message.conversation_id.in_(ids)).group_by(Message.conversation_id)
    last = db.info.setdefault("conv_last", {})
    last.update({c: None for c in ids})
    last.update({m.conversation_id: m for m in db.scalars(select(Message).where(Message.id.in_(newest)))})
    read_up_to = case((Conversation.buyer_id == user.id, Conversation.buyer_last_read_id),
                      else_=Conversation.seller_last_read_id)
    unread = db.info.setdefault("conv_unread", {})
    unread.update({c: 0 for c in ids})
    unread.update(dict(db.execute(
        select(Message.conversation_id, func.count(Message.id))
        .join(Conversation, Conversation.id == Message.conversation_id)
        .where(Message.conversation_id.in_(ids), Message.id > read_up_to, Message.sender_id != user.id)
        .group_by(Message.conversation_id)).all()))


def conversation_out(db: Session, conv: Conversation, user: User) -> dict:
    listing = db.info.get("conv_listing", {}).get(conv.listing_id) or db.get(Listing, conv.listing_id)
    me_buyer = user.id == conv.buyer_id
    people = db.info.get("conv_user", {})
    other_id = conv.seller_id if me_buyer else conv.buyer_id
    other = people.get(other_id) or db.get(User, other_id)
    last_read = conv.buyer_last_read_id if me_buyer else conv.seller_last_read_id
    if conv.id in db.info.get("conv_last", {}):
        last, unread = db.info["conv_last"][conv.id], db.info["conv_unread"][conv.id]
    else:
        last = db.scalar(select(Message).where(Message.conversation_id == conv.id).order_by(Message.id.desc()).limit(1))
        unread = db.scalar(select(func.count(Message.id)).where(
            Message.conversation_id == conv.id, Message.id > last_read, Message.sender_id != user.id))
    from .serializers import listing_cover  # serializers imports this module
    cover = listing_cover(listing)
    return {
        "id": conv.id, "listing_id": listing.id, "listing_title": listing.title, "listing_cover": cover,
        "price_tiyn": listing.price_tiyn, "role": "buyer" if me_buyer else "seller",
        # Names only, never phone numbers.
        "other_name": (other.shop_name if me_buyer else other.display_name) or ("Сатушы" if me_buyer else "Сатып алушы"),
        "last_message": message_out(last) if last else None, "unread": int(unread or 0),
        "seller_away_until": seller_away(people.get(conv.seller_id) or db.get(User, conv.seller_id)),
    }


def seller_away(seller: User | None) -> str | None:
    """The last day of the seller's holiday while it lasts, so a buyer knows why an answer may be slow."""
    today = now_utc().astimezone(timezone(timedelta(hours=5))).date()
    if seller is None or seller.away_until is None or seller.away_until < today:
        return None
    return seller.away_until.isoformat()


@router.post("/conversations", status_code=201)
def open_conversation(body: ConversationIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, body.listing_id)
    if listing is None or listing.status not in ("published", "sold"):
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    return conversation_out(db, the_conversation(db, listing.id, user.id, listing.seller_id), user)


def the_conversation(db: Session, listing_id: int, buyer_id: int, seller_id: int) -> Conversation:
    """The one chat of this buyer about this listing, made on the first ask. Two asks at once (a double tap) both
    get it: the one that loses the race to make it reads the other's."""
    def find() -> Conversation | None:
        return db.scalar(select(Conversation).where(Conversation.listing_id == listing_id,
                                                    Conversation.buyer_id == buyer_id))
    conv = find()
    if conv is None:
        db.add(Conversation(listing_id=listing_id, buyer_id=buyer_id, seller_id=seller_id))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
        conv = find()
    return conv


@router.post("/orders/{order_id}/conversation")
def order_conversation(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The chat about an order, from either side, even after the listing sold out or was taken down."""
    order = db.get(Order, order_id)
    if order is None or user.id not in (order.buyer_id, order.seller_id):
        raise ApiError(404, "not_found")
    services.ensure_not_blocked(db, order.buyer_id, order.seller_id)
    return conversation_out(db, the_conversation(db, order.listing_id, order.buyer_id, order.seller_id), user)


@router.get("/conversations")
def list_conversations(user: User = Depends(current_user), db: Session = Depends(get_db)):
    # Threads with someone this user blocked drop out of the list; the blocked side still sees theirs.
    mine = select(Block.blocked_id).where(Block.user_id == user.id)
    rows = db.scalars(select(Conversation).where(
        or_(and_(Conversation.buyer_id == user.id, Conversation.seller_id.not_in(mine)),
            and_(Conversation.seller_id == user.id, Conversation.buyer_id.not_in(mine))))
                      .order_by(Conversation.last_message_at.desc()).limit(100)).all()
    preload_conversations(db, rows, user)
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


def message_sent_by(db: Session, user: User, conv: Conversation, key: str) -> Message | None:
    """The message an earlier request with [key] put in this chat."""
    seen = IdempotencyRecord.made(db, user.id, f"message:{conv.id}", key)
    return None if seen is None else db.get(Message, seen.result_id)


@router.post("/conversations/{conversation_id}/messages", status_code=201)
def send_message(conversation_id: int, body: MessageIn, user: User = Depends(current_user),
                 db: Session = Depends(get_db),
                 idempotency_key: str | None = Header(default=None, min_length=8, max_length=100)):
    """With an Idempotency-Key, one per message typed in the app, a message sent again (its answer lost on weak
    mobile data) is the message the first one put in the chat, never a second copy for the other side."""
    conv = conversation_for(db, conversation_id, user)
    text = body.body.strip()
    if not text:
        raise ApiError(422, "validation", "empty message")
    if idempotency_key and (sent := message_sent_by(db, user, conv, idempotency_key)):
        return message_out(sent)
    return post_message(db, conv, user, text, None, key=idempotency_key)


@router.post("/conversations/{conversation_id}/photos", status_code=201)
def send_photo(conversation_id: int, file: UploadFile = File(...), caption: str = Form("", max_length=2000),
                     user: User = Depends(current_user), db: Session = Depends(get_db),
                     storage: Storage = Depends(get_storage),
                     idempotency_key: str | None = Header(default=None, min_length=8, max_length=100)):
    """A photo in the chat, e.g. a close-up the buyer asked for. Cleaned of metadata like any upload. Sent again with
    the same Idempotency-Key (its answer lost on weak mobile data), it is the message the first one posted: not stored
    or shown twice. Two at once may both store the file; the one not posted is swept with the other orphans."""
    conv = conversation_for(db, conversation_id, user)
    if idempotency_key and (sent := message_sent_by(db, user, conv, idempotency_key)):
        return message_out(sent)
    check_rate(db, user)
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    url = storage.put(normalize_image(data), owner_id=user.id)
    return post_message(db, conv, user, caption.strip(), url, key=idempotency_key)


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


def post_message(db: Session, conv: Conversation, user: User, text: str, photo_url: str | None,
                 key: str | None = None) -> dict:
    services.ensure_not_blocked(db, conv.buyer_id, conv.seller_id)
    check_rate(db, user)
    msg = Message(conversation_id=conv.id, sender_id=user.id, body=text, photo_url=photo_url,
                  contact_warning=bool(CONTACT_RE.search(text)))
    db.add(msg)
    db.flush()
    if key:
        db.add(IdempotencyRecord(user_id=user.id, scope=f"message:{conv.id}", key=key, result_id=msg.id))
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
    try:
        db.commit()
    except IntegrityError:
        # The same message arrived twice at once and the other request won: answer with its message, add none.
        db.rollback()
        sent = message_sent_by(db, user, conv, key) if key else None
        if sent is None:
            raise
        return message_out(sent)
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


def review_out(db: Session, r: Review, buyers: dict | None = None) -> dict:
    buyer = (buyers or {}).get(r.buyer_id) or db.get(User, r.buyer_id)
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
def upload_review_photo(order_id: int, file: UploadFile = File(...), user: User = Depends(current_user),
                              db: Session = Depends(get_db), storage: Storage = Depends(get_storage)):
    """A buyer's photo of the pair that arrived, for their review. Cleaned of metadata like any upload."""
    reviewable_order(db, order_id, user)
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    return {"url": storage.put(normalize_image(data), owner_id=user.id)}


@router.post("/orders/{order_id}/review", status_code=201)
def create_review(order_id: int, body: ReviewIn, user: User = Depends(current_user), db: Session = Depends(get_db),
                  storage: Storage = Depends(get_storage)):
    order = reviewable_order(db, order_id, user)
    # Only photos this buyer uploaded here: never a link to someone else's picture or another site.
    if not all(storage.owns(url, user.id) for url in body.photos):
        raise ApiError(422, "foreign_media")
    review = Review(order_id=order.id, seller_id=order.seller_id, buyer_id=user.id, rating=body.rating,
                    text=(body.text or "").strip() or None, photos=json.dumps(body.photos) if body.photos else None,
                    fit=body.fit)
    db.add(review)
    services.notify(db, order.seller_id, "review", f"Жаңа пікір: {body.rating}/5, тапсырыс №{order.id}.",
                    f"Новый отзыв: {body.rating}/5, заказ №{order.id}.",
                    f"New review: {body.rating}/5, order No. {order.id}.",
                    order_id=order.id)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()  # the same review sent twice at once, and the other one was kept
        raise ApiError(409, "already_reviewed") from None
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
    # Every reviewer of the page in one query, not one a review.
    buyers = {u.id: u for u in db.scalars(select(User).where(User.id.in_({r.buyer_id for r in rows})))} if rows else {}
    return {"seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
                       **seller_rating(db, seller.id)},
            "items": [review_out(db, r, buyers) for r in rows]}


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
