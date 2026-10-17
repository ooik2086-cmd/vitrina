"""VITRINA API v1 (modular monolith). Run: uvicorn vitrina_api.app:create_app --factory --reload"""
from __future__ import annotations

import collections
import csv
import hashlib
import hmac
import io
import json
import logging
import re
import secrets
import threading
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Depends, FastAPI, File, Header, Query, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import (BRAND_SYNONYMS, Authenticity, Condition, compute_bounds, normalize_query,
                                  transliterate)
from vitrina_core.orders import Actor, OrderStatus as S
from vitrina_core.webhooks import WebhookRejected, verify

from . import services
from . import authenticity, coupons, cutout, moderation, offers, promo, qa, visual
from .config import Settings
from .deps import current_user, get_db, get_settings, get_storage, now_utc, optional_user, sha256, staff_user
from .errors import ApiError, api_error_handler
from .share import router as share_router
from .social import reply_time, router as social_router, seller_rating, size_fit
from .models import (AuditLog, AuthToken, Block, Follow, Notification, Offer, SavedSearch, StockAlert, ListingDailyViews, ListingEmbedding, ListingReport, AuthToken, Favorite, IdempotencyRecord, Listing, ListingSize, Media, Order, OrderEvent,
                     OtpCode, Review, User, WebhookEvent, make_session_factory)
from .storage import MAX_UPLOAD_BYTES, LocalStorage, normalize_image

CATEGORIES = ("sneakers", "sport", "casual", "classic", "boots_winter", "sandals", "kids", "other")
PHONE_RE = re.compile(r"^\+7\d{10}$")
log = logging.getLogger(__name__)

MIN_SPIN_FRAMES = 8  # fewer real frames than this do not read as a rotation
DEFECT_REQUIRED = {Condition.USED_GOOD.value, Condition.DEFECTIVE.value}


# ---------------------------------------------------------------- schemas
class OtpRequest(BaseModel):
    phone: str


class OtpVerify(BaseModel):
    phone: str
    code: str = Field(min_length=6, max_length=6)


class ProfilePatch(BaseModel):
    display_name: str | None = Field(default=None, min_length=2, max_length=60)
    city: str | None = Field(default=None, max_length=60)


class SellerOn(BaseModel):
    shop_name: str = Field(min_length=2, max_length=80)
    city: str = Field(min_length=2, max_length=60)


class SizeIn(BaseModel):
    label: str = Field(min_length=1, max_length=20)
    insole_cm: str
    quantity: int = Field(ge=0, le=999)


class PhotoIn(BaseModel):
    url: str = Field(min_length=8, max_length=500)
    angle: Literal["front", "outer", "inner", "back", "top", "sole", "label", "defect", "frame"]


class ListingIn(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    category: Literal[CATEGORIES]  # type: ignore[valid-type]
    brand: str | None = Field(default=None, max_length=60)
    model_name: str | None = Field(default=None, max_length=80)
    color: str = Field(min_length=2, max_length=40)
    condition: Condition
    defects: str | None = Field(default=None, max_length=2000)
    description: str | None = Field(default=None, max_length=4000)
    price_tiyn: int = Field(gt=0, le=10**12)
    delivery_price_tiyn: int = Field(ge=0, le=10**10, default=0)
    showcase_style: Literal["clean", "premium", "dynamic"] = "clean"
    sizes: list[SizeIn] = Field(min_length=1, max_length=30)
    photos: list[PhotoIn] = Field(default_factory=list, max_length=60)


class StockIn(BaseModel):
    id: int
    quantity: int = Field(ge=0, le=999)


class ListingPatch(BaseModel):
    """What a seller may change after creating a listing. Photos, title and condition stay fixed so that
    buyers who saved or ordered the item see the same thing they chose."""
    price_tiyn: int | None = Field(default=None, gt=0, le=10**12)
    delivery_price_tiyn: int | None = Field(default=None, ge=0, le=10**10)
    description: str | None = Field(default=None, max_length=4000)
    defects: str | None = Field(default=None, max_length=2000)
    sizes: list[StockIn] | None = Field(default=None, max_length=30)


class DeliveryIn(BaseModel):
    recipient_name: str = Field(min_length=2, max_length=80)
    recipient_phone: str
    city: str = Field(min_length=2, max_length=60)
    address: str = Field(min_length=5, max_length=200)  # street, house, flat
    note: str | None = Field(default=None, max_length=200)


class OrderIn(BaseModel):
    listing_id: int
    size_id: int
    offer_id: int | None = None  # an accepted price offer for this listing and size
    promo_code: str | None = Field(default=None, max_length=20)  # the seller's code; not with an offer
    delivery: DeliveryIn


class ShipIn(BaseModel):
    tracking_number: str = Field(max_length=60)


class ReasonIn(BaseModel):
    reason: str = Field(max_length=2000)


class ReportIn(BaseModel):
    reason: Literal["fake", "wrong_photos", "prohibited", "contact_details", "other"]
    text: str | None = Field(default=None, max_length=1000)


class ReportCloseIn(BaseModel):
    action: Literal["hide", "dismiss"]
    reason: str = Field(min_length=3, max_length=2000)


class ResolveIn(BaseModel):
    refund_tiyn: int = Field(ge=0)
    reason: str = Field(max_length=2000)


# ---------------------------------------------------------------- serializers
def cm_to_mm(text: str) -> int:
    try:
        value = Decimal(text.replace(",", "."))
    except InvalidOperation as exc:
        raise ApiError(422, "validation", f"insole_cm: {text!r}") from exc
    if not Decimal("8") <= value <= Decimal("35"):
        raise ApiError(422, "validation", "insole_cm must be between 8 and 35")
    return int(value * 10)


def mm_to_cm(mm: int) -> str:
    return f"{mm // 10},{mm % 10}"


def segment_for(db: Session, listing: Listing) -> str | None:
    prices = db.scalars(select(Listing.price_tiyn).where(Listing.category == listing.category,
                                                         Listing.status.in_(("published", "sold")))).all()
    bounds = compute_bounds(listing.category, list(prices))
    return bounds.segment_for(listing.price_tiyn).value if bounds else None


def listing_stats(db: Session, listing: Listing) -> dict:
    """How the listing is doing, for its seller only."""
    from .models import Conversation
    count = lambda stmt: int(db.scalar(stmt) or 0)  # noqa: E731
    return {
        "views": listing.views,
        "favorites": count(select(func.count(Favorite.id)).where(Favorite.listing_id == listing.id)),
        "chats": count(select(func.count(Conversation.id)).where(Conversation.listing_id == listing.id)),
        "orders": count(select(func.count(Order.id)).where(Order.listing_id == listing.id,
                                                          Order.status != S.CANCELLED.value)),
        "sold": count(select(func.count(Order.id)).where(Order.listing_id == listing.id,
                                                        Order.status == S.COMPLETED.value)),
    }


def listing_out(db: Session, listing: Listing, *, owner: bool = False) -> dict:
    """owner=True adds stock counts and statistics, which only the seller sees."""
    seller = db.get(User, listing.seller_id)
    return {
        "id": listing.id, "status": listing.status, "title": listing.title, "category": listing.category,
        "brand": listing.brand, "model_name": listing.model_name, "color": listing.color,
        "price_tiyn": listing.price_tiyn, "was_price_tiyn": was_price(listing),
        "delivery_price_tiyn": listing.delivery_price_tiyn,
        # Three separate facts, never merged into one "quality" label.
        "segment": segment_for(db, listing), "condition": listing.condition, "authenticity": listing.authenticity,
        "defects": listing.defects, "description": listing.description, "showcase_style": listing.showcase_style,
        "sizes": [{"id": s.id, "label": s.label, "insole_cm": mm_to_cm(s.insole_mm), "available": s.quantity > 0,
                   **({"quantity": s.quantity} if owner else {})} for s in listing.sizes],
        "media": [{"original_url": m.original_url, "processed_url": m.processed_url, "angle": m.angle}
                  for m in listing.media],
        "seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,  # never the phone
                   "away_until": away_out(seller), **seller_rating(db, seller.id)},
        **({"stats": listing_stats(db, listing),
            "promo": {"state": listing.promo_state, "url": listing.promo_url},
            "moderation": moderation_out(listing)} if owner else {}),
    }


SALE_DAYS = 14  # how long a cut price is shown against the old one


def mark_price_change(listing: Listing, new_price: int) -> None:
    """Keep the highest price of the current sale as the crossed-out one; a cut of under 5% is not a sale."""
    now = now_utc()
    live = listing.was_price_tiyn if listing.was_until and services.aware(listing.was_until) > now else None
    was = max(live or 0, listing.price_tiyn)
    if new_price <= was * 0.95:
        listing.was_price_tiyn, listing.was_until = was, now + timedelta(days=SALE_DAYS)
    elif new_price >= was or live is None:
        listing.was_price_tiyn, listing.was_until = None, None


def was_price(listing: Listing) -> int | None:
    if listing.was_price_tiyn and listing.was_until and services.aware(listing.was_until) > now_utc() \
            and listing.was_price_tiyn > listing.price_tiyn:
        return listing.was_price_tiyn
    return None


def moderation_out(listing: Listing) -> dict:
    flags = [c for c in (listing.moderation_flags or "").split(",") if c]
    return {"flags": flags, "reasons": [moderation.REASONS[c][0] for c in flags if c in moderation.REASONS],
            "reasons_ru": [moderation.REASONS[c][1] for c in flags if c in moderation.REASONS],
            "note": listing.moderation_note}


def order_out(order: Order) -> dict:
    return {
        "id": order.id, "status": order.status, "listing_id": order.listing_id, "size_id": order.size_id,
        "buyer_id": order.buyer_id, "seller_id": order.seller_id,
        "item_price_tiyn": order.item_price_tiyn, "delivery_price_tiyn": order.delivery_price_tiyn,
        "total_tiyn": services.total_tiyn(order), "tracking_number": order.tracking_number,
        "promo_code": order.promo_code, "promo_discount_tiyn": order.promo_discount_tiyn or 0,
        "delivered_at": services.aware(order.delivered_at).isoformat() if order.delivered_at else None,
    }


ADDRESS_HIDDEN_UNTIL_PAID = (S.CREATED.value, S.PAYMENT_PENDING.value, S.CANCELLED.value)


def delivery_out(order: Order, viewer: User) -> dict | None:
    """The address for the buyer always, and for the seller once the order is paid: an unpaid order is not
    a reason to hand a stranger's home address over."""
    if order.delivery_address is None:
        return None
    if viewer.id != order.buyer_id and order.status in ADDRESS_HIDDEN_UNTIL_PAID:
        return None
    return {"recipient_name": order.recipient_name, "recipient_phone": order.recipient_phone,
            "city": order.delivery_city, "address": order.delivery_address, "note": order.delivery_note}


def order_summary(db: Session, order: Order) -> dict:
    """Order plus what a list row needs to be recognisable: the item's title, size and photo."""
    listing = db.get(Listing, order.listing_id)
    size = db.get(ListingSize, order.size_id)
    cover = next((m.processed_url or m.original_url for m in listing.media if m.angle != "frame"), None)
    return {**order_out(order), "listing_title": listing.title, "listing_cover": cover,
            "size_label": size.label, "size_cm": mm_to_cm(size.insole_mm),
            "seller_name": db.get(User, order.seller_id).shop_name, "created_at": services.aware(order.created_at).isoformat()}


def away_until(user: User | None):
    """The last day of a seller's holiday, while it lasts; None otherwise."""
    if user is None or user.away_until is None:
        return None
    return user.away_until if user.away_until >= now_utc().astimezone(ALMATY).date() else None


def away_out(user: User | None) -> str | None:
    day = away_until(user)
    return day.isoformat() if day else None


def me_out(user: User) -> dict:
    return {"id": user.id, "phone": user.phone, "display_name": user.display_name, "city": user.city,
            "is_seller": user.is_seller, "shop_name": user.shop_name, "role": user.role,
            "away_until": away_out(user), "last_delivery": json.loads(user.last_delivery) if user.last_delivery else None}


# ---------------------------------------------------------------- auth + profile
api = APIRouter(prefix="/api/v1")


@api.post("/auth/otp")
def request_otp(body: OtpRequest, db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    if not PHONE_RE.match(body.phone):
        raise ApiError(422, "invalid_phone")
    recent = db.scalar(select(func.count(OtpCode.id)).where(OtpCode.phone == body.phone,
                                                            OtpCode.created_at > now_utc() - timedelta(hours=1)))
    if recent >= cfg.otp_per_phone_per_hour:
        raise ApiError(429, "rate_limited")
    code = f"{secrets.randbelow(10**6):06d}"
    digest = hmac.new(cfg.otp_secret, f"{body.phone}:{code}".encode(), hashlib.sha256).hexdigest()
    db.add(OtpCode(phone=body.phone, code_hash=digest, expires_at=now_utc() + cfg.otp_ttl))
    db.commit()
    # TODO(sms): send `code` through the SMS provider once one is contracted.
    return {"sent": True, **({"dev_code": code} if cfg.debug_otp else {})}


@api.post("/auth/verify")
def verify_otp(body: OtpVerify, db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    otp = db.scalar(select(OtpCode).where(OtpCode.phone == body.phone, OtpCode.used.is_(False))
                    .order_by(OtpCode.id.desc()))
    if otp is None or services.aware(otp.expires_at) < now_utc() or otp.attempts >= cfg.otp_max_attempts:
        raise ApiError(400, "otp_expired")
    digest = hmac.new(cfg.otp_secret, f"{body.phone}:{body.code}".encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(digest, otp.code_hash):
        otp.attempts += 1
        db.commit()
        raise ApiError(400, "otp_invalid")
    otp.used = True
    user = db.scalar(select(User).where(User.phone == body.phone))
    if user is None:
        user = User(phone=body.phone)
        db.add(user)
        db.flush()
    if user.is_blocked:
        db.commit()
        raise ApiError(403, "forbidden", "account blocked")
    raw = secrets.token_urlsafe(32)
    db.add(AuthToken(token_hash=sha256(raw), user_id=user.id, expires_at=now_utc() + cfg.token_ttl))
    db.commit()
    return {"token": raw, "user": me_out(user)}


@api.get("/me")
def get_me(user: User = Depends(current_user)):
    return me_out(user)


def notification_settings(user: User) -> dict:
    off = services.muted(user)
    return {"items": [{"kind": k, "on": k not in off} for k in services.OPTIONAL_KINDS]}


@api.get("/me/notification-settings")
def get_notification_settings(user: User = Depends(current_user)):
    return notification_settings(user)


@api.put("/me/notification-settings")
def put_notification_settings(body: dict[str, bool], user: User = Depends(current_user),
                              db: Session = Depends(get_db)):
    """Turns optional alerts on or off, e.g. {"price_drop": false}. Kinds that always arrive cannot be listed."""
    unknown = set(body) - set(services.OPTIONAL_KINDS)
    if unknown:
        raise ApiError(422, "validation", f"cannot mute {sorted(unknown)}")
    off = services.muted(user)
    for kind, on in body.items():
        (off.discard if on else off.add)(kind)
    user.muted_kinds = ",".join(sorted(off)) or None
    db.commit()
    return notification_settings(user)


@api.delete("/me")
def delete_me(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Deletes the account: personal data goes, the person is signed out everywhere and their listings leave the
    catalog. Orders, payments and the ledger stay, without the name, because the law requires keeping them."""
    open_orders = db.scalar(select(func.count(Order.id)).where(
        or_(Order.buyer_id == user.id, Order.seller_id == user.id),
        Order.status.not_in([s.value for s in (S.COMPLETED, S.REFUNDED, S.CANCELLED)])))
    if open_orders:
        raise ApiError(409, "open_orders")
    now = now_utc()
    for model, column in ((Favorite, Favorite.user_id), (SavedSearch, SavedSearch.user_id),
                          (Follow, Follow.user_id), (Follow, Follow.seller_id), (StockAlert, StockAlert.user_id),
                          (Notification, Notification.user_id), (Block, Block.user_id), (Block, Block.blocked_id)):
        db.execute(delete(model).where(column == user.id))
    db.execute(update(AuthToken).where(AuthToken.user_id == user.id).values(revoked=True))
    db.execute(update(Offer).where(or_(Offer.buyer_id == user.id, Offer.seller_id == user.id),
                                   Offer.status.in_(offers.OPEN)).values(status="withdrawn"))
    db.execute(update(Listing).where(Listing.seller_id == user.id, Listing.status.not_in(("sold", "hidden")))
               .values(status="paused"))
    services.audit(db, user.id, "delete_account", f"user:{user.id}")
    user.phone = f"deleted:{user.id}"  # frees the number: signing in with it again starts a new account
    user.display_name = user.city = user.shop_name = user.last_delivery = user.away_until = None
    user.is_blocked, user.deleted_at = True, now
    db.commit()
    return {"deleted": True}


@api.patch("/me")
def patch_me(body: ProfilePatch, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user = db.merge(user)
    for k, v in body.model_dump(exclude_unset=True).items():
        setattr(user, k, v)
    db.commit()
    return me_out(user)


MAX_AWAY_DAYS = 60


class AwayIn(BaseModel):
    until: date | None = None  # None ends the holiday


@api.put("/me/away")
def set_away(body: AwayIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Holiday mode: listings stay visible with a note, but nobody can order or make an offer until the seller
    is back, so no one pays and then waits for a shop that is closed."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    today = now_utc().astimezone(ALMATY).date()
    if body.until is not None and not today <= body.until <= today + timedelta(days=MAX_AWAY_DAYS):
        raise ApiError(422, "validation", f"until must be within {MAX_AWAY_DAYS} days from today")
    user = db.merge(user)
    user.away_until = body.until
    db.commit()
    return me_out(user)


@api.post("/me/seller")
def become_seller(body: SellerOn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user = db.merge(user)
    user.is_seller, user.shop_name, user.city = True, body.shop_name, body.city
    db.commit()
    return me_out(user)


# ---------------------------------------------------------------- listings + search
def search_text(body: ListingIn) -> str:
    return normalize_query(" ".join(filter(None, [body.title, body.brand, body.model_name, body.color, body.category])))


@api.post("/media", status_code=201)
async def upload_photo(file: UploadFile = File(...), user: User = Depends(current_user),
                       storage: LocalStorage = Depends(get_storage)):
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    return {"url": storage.put(normalize_image(data), owner_id=user.id)}


@api.get("/me/listings")
def my_listings(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Listing).where(Listing.seller_id == user.id).order_by(Listing.id.desc()).limit(200)).all()
    return {"items": [listing_out(db, r, owner=True) for r in rows]}


@api.get("/me/earnings")
def my_earnings(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Seller's money, read straight from the ledger: what is held for open orders, what is owed to the
    seller after completed ones, and the commission taken on each."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    from vitrina_core.money import PLATFORM_FEE, escrow, seller_payable
    from .models import LedgerEntry, LedgerTx
    orders = {o.id: o for o in db.scalars(select(Order).where(Order.seller_id == user.id)).all()}
    held = sum(services.balance(db, escrow(str(oid))) for oid in orders)
    items = []
    if orders:
        txs = db.scalars(select(LedgerTx).where(LedgerTx.order_id.in_(orders),
                                                LedgerTx.idempotency_key.like("settle:%"))
                         .order_by(LedgerTx.id.desc()).limit(100)).all()
        mine = seller_payable(str(user.id))
        for tx in txs:
            net = sum(e.credit - e.debit for e in tx.entries if e.account == mine)
            fee = sum(e.credit - e.debit for e in tx.entries if e.account == PLATFORM_FEE)
            order = orders[tx.order_id]
            items.append({"order_id": order.id, "kind": tx.kind, "at": services.aware(tx.at).isoformat(),
                          "listing_title": db.get(Listing, order.listing_id).title,
                          "net_tiyn": net, "fee_tiyn": fee})
    fees = db.scalar(select(func.coalesce(func.sum(LedgerEntry.credit - LedgerEntry.debit), 0))
                     .join(LedgerTx, LedgerTx.id == LedgerEntry.tx_id)
                     .where(LedgerEntry.account == PLATFORM_FEE, LedgerTx.order_id.in_(orders or [0])))
    return {"held_tiyn": held, "payable_tiyn": services.balance(db, seller_payable(str(user.id))),
            "fees_tiyn": int(fees or 0), "items": items}


STATUS_KK = {
    "CREATED": "Жасалды", "PAYMENT_PENDING": "Төлем күтілуде", "PAID": "Төленді", "SELLER_ACCEPTED": "Қабылданды",
    "PREPARING": "Дайындалуда", "SHIPPED": "Жіберілді", "IN_TRANSIT": "Жолда",
    "DELIVERED_PENDING_CONFIRMATION": "Жеткізілді", "COMPLETED": "Аяқталды", "DISPUTED": "Дау",
    "RETURN_REQUESTED": "Қайтару сұралды", "REFUND_PENDING": "Ақша қайтарылуда", "REFUNDED": "Ақша қайтарылды",
    "CANCELLED": "Бас тартылды",
}


def tenge(tiyn: int | None) -> str:
    """Tenge for a spreadsheet in Kazakhstan: decimal comma, no thousands separator."""
    if tiyn is None:
        return ""
    whole, part = divmod(abs(tiyn), 100)
    return ("-" if tiyn < 0 else "") + (f"{whole},{part:02d}" if part else str(whole))


@api.get("/me/sales.csv")
def sales_csv(days: int = Query(default=90, ge=1, le=366), user: User = Depends(current_user),
              db: Session = Depends(get_db)):
    """The seller's orders for a spreadsheet or an accountant: price, promo, commission and what was paid out.
    Semicolons and a byte-order mark so Excel opens it right in a Russian or Kazakh locale."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    from vitrina_core.money import PLATFORM_FEE, seller_payable
    from .models import LedgerTx
    since = now_utc() - timedelta(days=days)
    orders = db.scalars(select(Order).where(Order.seller_id == user.id, Order.created_at >= since)
                        .order_by(Order.id)).all()
    mine = seller_payable(str(user.id))
    out = io.StringIO()
    w = csv.writer(out, delimiter=";", lineterminator="\r\n")
    w.writerow(["Тапсырыс", "Күні", "Күйі", "Тауар", "Өлшем", "Тауар бағасы, ₸", "Промокод", "Жеңілдік, ₸",
                "Жеткізу, ₸", "Комиссия, ₸", "Сізге, ₸", "Алушы қаласы"])
    for o in orders:
        settled = db.scalars(select(LedgerTx).where(LedgerTx.order_id == o.id,
                                                    LedgerTx.idempotency_key.like("settle:%"))).all()
        fee = sum(e.credit - e.debit for tx in settled for e in tx.entries if e.account == PLATFORM_FEE)
        net = sum(e.credit - e.debit for tx in settled for e in tx.entries if e.account == mine)
        size = db.get(ListingSize, o.size_id)
        paid = o.status not in ADDRESS_HIDDEN_UNTIL_PAID  # the buyer's city only once they have paid
        w.writerow([o.id, services.aware(o.created_at).astimezone(ALMATY).strftime("%d.%m.%Y %H:%M"),
                    STATUS_KK.get(o.status, o.status), db.get(Listing, o.listing_id).title, size.label if size else "",
                    tenge(o.item_price_tiyn), o.promo_code or "", tenge(o.promo_discount_tiyn) if o.promo_code else "",
                    tenge(o.delivery_price_tiyn), tenge(fee) if settled else "", tenge(net) if settled else "",
                    (o.delivery_city or "") if paid else ""])
    name = f"vitrina-sales-{now_utc().astimezone(ALMATY):%Y-%m-%d}.csv"
    return Response(content="\ufeff" + out.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


# Labels and defect close-ups stay as taken: their surroundings are part of what they prove.
CUTOUT_ANGLES = {"front", "outer", "inner", "back", "top", "sole", "frame"}


def cutout_listing(state, listing_id: int) -> int:
    """Background job: add a transparent-background version of each showcase photo of one listing."""
    segment, storage = state.segmenter, state.storage
    if segment is None:
        return 0
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return 0
        media = [m for m in listing.media if m.angle in CUTOUT_ANGLES and storage.owns(m.original_url)]
        done = cutout.process_listing_media(
            media, storage.read, lambda data: storage.put(data, owner_id=listing.seller_id, ext="webp"), segment)
        db.commit()
        return done


def embed_listing(state, listing_id: int) -> bool:
    """Background job: store the search-by-photo vector of a listing's main photo."""
    embed, storage = state.embedder, state.storage
    if embed is None:
        return False
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return False
        photos = sorted((m for m in listing.media if m.angle in ("front", "outer", "inner", "back")),
                        key=lambda m: ("front", "outer", "inner", "back").index(m.angle))
        photo = next((m for m in photos if storage.owns(m.processed_url or m.original_url)), None)
        if photo is None:
            return False
        vector = embed(storage.read(photo.processed_url or photo.original_url))
        row = db.get(ListingEmbedding, listing.id) or ListingEmbedding(listing_id=listing.id)
        row.model, row.vector, row.updated_at = visual.MODEL_NAME, vector.tobytes(), now_utc()
        db.merge(row)
        db.commit()
        return True


SPIN_PROMO_MAX_FRAMES = 36


def render_listing_promo(state, listing_id: int, lang: str) -> bool:
    """Background job: the shareable promo video. Uses the 360° frames when there are any, else the angle photos."""
    storage = state.storage
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return False
        media = sorted(listing.media, key=lambda m: m.position)
        frames = [m for m in media if m.angle == "frame"]
        spin = len(frames) >= MIN_SPIN_FRAMES
        chosen = frames[:SPIN_PROMO_MAX_FRAMES] if spin else [m for m in media if m.angle in PROMO_ANGLES]
        try:
            photos = [Image.open(io.BytesIO(storage.read(m.processed_url or m.original_url))) for m in chosen
                      if storage.owns(m.processed_url or m.original_url)]
            video = promo.render_video(photos, title=listing.title, price=promo.format_tenge(listing.price_tiyn),
                                       style=listing.showcase_style, lang=lang, spin=spin)
            listing.promo_url = storage.put(video, owner_id=listing.seller_id, ext="mp4")
            listing.promo_state = "ready"
        except Exception:
            log.exception("promo video failed for listing %s", listing_id)
            listing.promo_state = "failed"
        db.commit()
        return listing.promo_state == "ready"


PROMO_ANGLES = ("outer", "front", "inner", "back", "top")


def prepare_listing_media(state, listing_id: int) -> None:
    # Cut-outs first, so the search vector is computed on the shoe without its backdrop.
    cutout_listing(state, listing_id)
    embed_listing(state, listing_id)


@api.post("/listings", status_code=201)
def create_listing(body: ListingIn, request: Request, background: BackgroundTasks,
                   user: User = Depends(current_user), db: Session = Depends(get_db),
                   cfg: Settings = Depends(get_settings), storage: LocalStorage = Depends(get_storage)):
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    if not cfg.allow_external_media and not all(storage.owns(p.url) for p in body.photos):
        raise ApiError(422, "foreign_media")
    frames = sum(p.angle == "frame" for p in body.photos)
    if 0 < frames < MIN_SPIN_FRAMES:
        raise ApiError(422, "too_few_frames")
    listing = Listing(
        seller_id=user.id, title=body.title, category=body.category, brand=body.brand, model_name=body.model_name,
        color=body.color, condition=body.condition.value, defects=body.defects, description=body.description,
        price_tiyn=body.price_tiyn, delivery_price_tiyn=body.delivery_price_tiyn,
        showcase_style=body.showcase_style, search_text=search_text(body),
        authenticity=Authenticity.UNVERIFIED.value,
        sizes=[ListingSize(label=s.label, insole_mm=cm_to_mm(s.insole_cm), quantity=s.quantity) for s in body.sizes],
        media=[Media(original_url=p.url, angle=p.angle, position=i) for i, p in enumerate(body.photos)],
    )
    db.add(listing)
    db.commit()
    background.add_task(prepare_listing_media, request.app.state, listing.id)
    return listing_out(db, listing, owner=True)


def own_listing(db: Session, listing_id: int, user: User) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None or listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    return listing


@api.post("/listings/{listing_id}/publish")
def publish_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
                    cfg: Settings = Depends(get_settings), storage: LocalStorage = Depends(get_storage)):
    listing = own_listing(db, listing_id, user)
    # "hidden" is a moderation decision; only staff can lift it. A "rejected" listing is fixed and sent again.
    if listing.status not in ("draft", "paused", "rejected"):
        raise ApiError(409, "invalid_status")
    if len(listing.media) < cfg.min_listing_photos:
        raise ApiError(422, "missing_required_photos")
    if listing.condition in DEFECT_REQUIRED and not (listing.defects or "").strip():
        raise ApiError(422, "defects_required")
    if listing.condition == Condition.DEFECTIVE.value and not any(m.angle == "defect" for m in listing.media):
        raise ApiError(422, "defects_required", "a close-up photo of each defect is required")
    if not any(s.quantity > 0 for s in listing.sizes):
        raise ApiError(422, "out_of_stock")
    route_after_checks(db, storage, listing)
    db.commit()
    return listing_out(db, listing, owner=True)


def split_codes(text: str | None) -> list[str]:
    return [c for c in (text or "").split(",") if c]


def route_after_checks(db: Session, storage: LocalStorage, listing: Listing) -> None:
    """Publish, or queue for staff when a check flags something staff have not already cleared."""
    flags = moderation.check(db, storage, listing)
    listing.moderation_flags = ",".join(flags) or None
    if set(flags) - set(split_codes(listing.moderation_cleared)):
        listing.status = "moderation"
    else:
        listing.status = "published"
        listing.moderation_note = None
        announce(db, listing)
        services.tell_back_in_stock(db, listing)


@api.patch("/listings/{listing_id}")
def edit_listing(listing_id: int, body: ListingPatch, user: User = Depends(current_user),
                 db: Session = Depends(get_db), storage: LocalStorage = Depends(get_storage)):
    listing = own_listing(db, listing_id, user)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    if body.price_tiyn is not None:
        if body.price_tiyn != listing.price_tiyn and listing.promo_state == "ready":
            listing.promo_state, listing.promo_url = None, None  # the video shows the old price
        if body.price_tiyn < listing.price_tiyn and listing.status == "published":
            notify_price_drop(db, listing, listing.price_tiyn, body.price_tiyn)
        mark_price_change(listing, body.price_tiyn)
        listing.price_tiyn = body.price_tiyn
    if body.delivery_price_tiyn is not None:
        listing.delivery_price_tiyn = body.delivery_price_tiyn
    if body.description is not None:
        listing.description = body.description.strip() or None
    if body.defects is not None:
        if listing.condition in DEFECT_REQUIRED and not body.defects.strip():
            raise ApiError(422, "defects_required")
        listing.defects = body.defects.strip() or None
    if body.sizes is not None:
        by_id = {s.id: s for s in listing.sizes}
        for item in body.sizes:
            if item.id not in by_id:
                raise ApiError(422, "validation", f"unknown size {item.id}")
            by_id[item.id].quantity = item.quantity
        in_stock = any(s.quantity > 0 for s in listing.sizes)
        if listing.status == "published" and not in_stock:
            listing.status = "sold"
        elif listing.status == "sold" and in_stock:
            listing.status = "paused"  # restocked; the seller republishes when ready
    if listing.status == "published" and (body.price_tiyn is not None or body.description is not None
                                          or body.defects is not None):
        route_after_checks(db, storage, listing)  # a live listing cannot slip a phone number in later
    services.tell_back_in_stock(db, listing)
    db.commit()
    return listing_out(db, listing, owner=True)


class PromoIn(BaseModel):
    lang: Literal["kk", "ru"] = "kk"


@api.post("/listings/{listing_id}/promo", status_code=202)
def make_promo(listing_id: int, body: PromoIn, request: Request, background: BackgroundTasks,
               user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    if not promo.available():
        raise ApiError(503, "promo_off")
    listing.promo_state, listing.promo_url = "rendering", None
    db.commit()
    background.add_task(render_listing_promo, request.app.state, listing.id, body.lang)
    return listing_out(db, listing, owner=True)


def notify_price_drop(db: Session, listing: Listing, old: int, new: int) -> None:
    """Tell everyone who saved the listing that it got cheaper. Small trims (under 1%) are not news."""
    if (old - new) * 100 < old:
        return
    old_text, new_text = promo.format_tenge(old), promo.format_tenge(new)
    for user_id in db.scalars(select(Favorite.user_id).where(Favorite.listing_id == listing.id)):
        if user_id != listing.seller_id:
            services.notify(db, user_id, "price_drop",
                            f"«{listing.title}» арзандады: {old_text} → {new_text}",
                            f"«{listing.title}» подешевел: {old_text} → {new_text}", listing_id=listing.id)


@api.post("/listings/{listing_id}/pause")
def pause_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status != "published":
        raise ApiError(409, "invalid_status")
    listing.status = "paused"
    db.commit()
    return listing_out(db, listing, owner=True)


def catalog_filter(stmt, *, q: str | None = None, category: str | None = None, brand: str | None = None,
                   condition: str | None = None, min_price_tiyn: int | None = None,
                   max_price_tiyn: int | None = None, size_cm: str | None = None):
    """The catalog's filters, shared by search and by saved-search alerts so both agree on what matches."""
    if q:
        for token in normalize_query(q).split():
            stmt = stmt.where(Listing.search_text.contains(token))
    if category:
        stmt = stmt.where(Listing.category == category)
    if brand:
        stmt = stmt.where(Listing.search_text.contains(normalize_query(brand)))
    if condition:  # one value or a comma-separated list
        stmt = stmt.where(Listing.condition.in_([c for c in condition.split(",") if c]))
    if min_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn >= min_price_tiyn)
    if max_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn <= max_price_tiyn)
    if size_cm:
        mm = cm_to_mm(size_cm)
        stmt = stmt.where(Listing.id.in_(select(ListingSize.listing_id).where(
            ListingSize.quantity > 0, ListingSize.insole_mm.between(mm - 5, mm + 5))))
    return stmt


@api.get("/listings")
def search_listings(q: str | None = None, category: str | None = None, brand: str | None = None,
                    condition: str | None = None, min_price_tiyn: int | None = None,
                    max_price_tiyn: int | None = None, size_cm: str | None = None,
                    sort: Literal["new", "price_asc", "price_desc"] = "new", seller_id: int | None = None,
                    sale: bool = False, limit: int = 20, offset: int = 0, db: Session = Depends(get_db)):
    stmt = catalog_filter(select(Listing).where(Listing.status == "published"), q=q, category=category,
                          brand=brand, condition=condition, min_price_tiyn=min_price_tiyn,
                          max_price_tiyn=max_price_tiyn, size_cm=size_cm)
    if seller_id is not None:
        stmt = stmt.where(Listing.seller_id == seller_id)
    if sale:
        stmt = stmt.where(Listing.was_price_tiyn > Listing.price_tiyn, Listing.was_until > now_utc())
    order = {"new": (Listing.id.desc(),), "price_asc": (Listing.price_tiyn, Listing.id.desc()),
             "price_desc": (Listing.price_tiyn.desc(), Listing.id.desc())}[sort]
    rows = db.scalars(stmt.order_by(*order).limit(max(1, min(limit, 50))).offset(max(0, offset))).all()
    return {"items": [listing_out(db, r) for r in rows]}


@api.post("/listings/{listing_id}/report", status_code=201)
def report_listing(listing_id: int, body: ReportIn, user: User = Depends(current_user),
                   db: Session = Depends(get_db)):
    """Reports only queue a listing for a moderator; they never hide it by themselves, so competitors
    cannot take a listing down by reporting it."""
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    if body.reason == "other" and not (body.text or "").strip():
        raise ApiError(422, "reason_required")
    db.add(ListingReport(listing_id=listing.id, reporter_id=user.id, reason=body.reason,
                         text=(body.text or "").strip() or None))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise ApiError(409, "already_reported")
    return {"reported": True}


def public_seller(db: Session, seller_id: int) -> User:
    seller = db.get(User, seller_id)
    if seller is None or not seller.is_seller or seller.is_blocked:
        raise ApiError(404, "not_found")
    return seller


def followers(db: Session, seller_id: int) -> int:
    return int(db.scalar(select(func.count(Follow.id)).where(Follow.seller_id == seller_id)) or 0)


@api.get("/sellers/{seller_id}")
def seller_profile(seller_id: int, user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    """Public shop card. Counts come from the platform's own records, not from what the seller typed."""
    seller = public_seller(db, seller_id)
    sales = db.scalar(select(func.count(Order.id)).where(Order.seller_id == seller.id,
                                                         Order.status == S.COMPLETED.value))
    live = db.scalar(select(func.count(Listing.id)).where(Listing.seller_id == seller.id,
                                                          Listing.status == "published"))
    return {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
            "since": services.aware(seller.created_at).date().isoformat(),
            "completed_sales": int(sales or 0), "listings": int(live or 0), "away_until": away_out(seller),
            "followers": followers(db, seller.id), "reply_time": reply_time(db, seller.id),
            "following": user is not None and db.scalar(select(Follow.id).where(
                Follow.user_id == user.id, Follow.seller_id == seller.id)) is not None,
            **seller_rating(db, seller.id)}


@api.put("/sellers/{seller_id}/follow")
def follow_seller(seller_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller = public_seller(db, seller_id)
    if seller.id == user.id:
        raise ApiError(409, "own_shop")
    if db.scalar(select(Follow.id).where(Follow.user_id == user.id, Follow.seller_id == seller.id)) is None:
        db.add(Follow(user_id=user.id, seller_id=seller.id))
        try:
            db.commit()
        except IntegrityError:  # a double tap; the follow is there either way
            db.rollback()
    return {"following": True, "followers": followers(db, seller.id)}


@api.delete("/sellers/{seller_id}/follow")
def unfollow_seller(seller_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    for f in db.scalars(select(Follow).where(Follow.user_id == user.id, Follow.seller_id == seller_id)).all():
        db.delete(f)
    db.commit()
    return {"following": False, "followers": followers(db, seller_id)}


@api.get("/me/following")
def my_following(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Shops the user follows, newest first, with how many listings each has on sale now."""
    rows = db.execute(select(User, Follow.created_at).join(Follow, Follow.seller_id == User.id).where(
        Follow.user_id == user.id, User.is_blocked.is_(False)).order_by(Follow.id.desc())).all()
    items = []
    for seller, _ in rows:
        live = db.scalar(select(func.count(Listing.id)).where(Listing.seller_id == seller.id,
                                                              Listing.status == "published"))
        items.append({"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
                      "listings": int(live or 0), "away_until": away_out(seller), **seller_rating(db, seller.id)})
    return {"items": items}


class SlidingWindowLimiter:
    """In-process limit per key. Enough for one API process; several processes need a shared store (Redis)."""

    def __init__(self, limit: int, window_s: float):
        self.limit, self.window = limit, window_s
        self._hits: dict[str, collections.deque] = collections.defaultdict(collections.deque)
        self._lock = threading.Lock()

    def allow(self, key: str, now: float) -> bool:
        with self._lock:
            hits = self._hits[key]
            while hits and hits[0] <= now - self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True


IMAGE_SEARCH_PER_MINUTE = 20


@api.post("/search/image")
async def search_by_image(request: Request, file: UploadFile = File(...), category: str | None = None,
                          size_cm: str | None = None, limit: int = 20, db: Session = Depends(get_db)):
    """Listings that look like the uploaded photo, most similar first. The photo is not stored."""
    embed = request.app.state.embedder
    if embed is None:
        raise ApiError(503, "image_search_off")
    client = request.client.host if request.client else "unknown"
    if not request.app.state.image_search_limiter.allow(client, time.monotonic()):
        raise ApiError(429, "rate_limited")
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    import numpy as np
    query = embed(normalize_image(data))
    stmt = (select(Listing, ListingEmbedding.vector).join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
            .where(Listing.status == "published", ListingEmbedding.model == visual.MODEL_NAME))
    if category:
        stmt = stmt.where(Listing.category == category)
    if size_cm:
        mm = cm_to_mm(size_cm)
        stmt = stmt.where(Listing.id.in_(select(ListingSize.listing_id).where(
            ListingSize.quantity > 0, ListingSize.insole_mm.between(mm - 5, mm + 5))))
    # Brute force is fine at MVP scale; move to pgvector once the catalogue passes ~50k listings.
    scored = sorted(((float(np.frombuffer(vec, np.float32) @ query), listing) for listing, vec in db.execute(stmt)),
                    key=lambda t: -t[0])[:max(1, min(limit, 50))]
    return {"items": [{**listing_out(db, listing), "similarity": round(score, 3)} for score, listing in scored]}


SUGGEST_MIN_SHAPE = 0.70  # shape-only cosine; same model in another colour scores ~0.8, unrelated objects ~0.4
SUGGEST_NEIGHBOURS = 5


class SuggestIn(BaseModel):
    photo_url: str = Field(max_length=500)


@api.post("/listings/suggest")
def suggest_details(body: SuggestIn, request: Request, user: User = Depends(current_user),
                    db: Session = Depends(get_db), storage: LocalStorage = Depends(get_storage)):
    """Brand, model and category to offer the seller, read off look-alike listings already on VITRINA.

    Only shape counts (the colour part is dropped), since the same model comes in many colours.
    Each field is offered only when the neighbours agree on it; the seller decides whether to use it."""
    embed = request.app.state.embedder
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    if embed is None:
        raise ApiError(503, "image_search_off")
    if not storage.owns(body.photo_url):
        raise ApiError(422, "foreign_media")
    import numpy as np
    full = embed(storage.read(body.photo_url))
    shape_dims = full.size - visual.COLOR_BINS
    query = full[:shape_dims] / (np.linalg.norm(full[:shape_dims]) + 1e-8)
    rows = db.execute(select(Listing, ListingEmbedding.vector)
                      .join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
                      .where(Listing.status.in_(("published", "sold")), ListingEmbedding.model == visual.MODEL_NAME))
    scored = []
    for listing, vec in rows:
        shape = np.frombuffer(vec, np.float32)[:shape_dims]
        score = float(shape @ query) / (float(np.linalg.norm(shape)) + 1e-8)
        if score >= SUGGEST_MIN_SHAPE:
            scored.append((score, listing))
    near = sorted(scored, key=lambda t: -t[0])[:SUGGEST_NEIGHBOURS]

    def vote(get):
        tally: dict[str, float] = collections.defaultdict(float)
        for score, listing in near:
            value = (get(listing) or "").strip()
            if value:
                tally[value] += score
        if not tally:
            return None
        value, weight = max(tally.items(), key=lambda kv: kv[1])
        return value if weight >= 0.6 * sum(tally.values()) else None  # a clear majority, or nothing

    brand = vote(lambda l: l.brand)
    return {
        "category": vote(lambda l: l.category),
        "brand": brand,
        "model_name": vote(lambda l: l.model_name if l.brand == brand else None) if brand else None,
        "based_on": len(near),
        "best_similarity": round(near[0][0], 3) if near else None,
    }


@api.get("/listings/{listing_id}/similar")
def similar_listings(listing_id: int, limit: int = 10, db: Session = Depends(get_db)):
    """Look-alike listings, ranked with the stored photo vectors.
    Empty when the listing has no vector yet (no model, or its photos are still being prepared)."""
    import numpy as np
    own = db.get(ListingEmbedding, listing_id)
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    if own is None or own.model != visual.MODEL_NAME:
        return {"items": []}
    query = np.frombuffer(own.vector, np.float32)
    rows = db.execute(select(Listing, ListingEmbedding.vector)
                      .join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
                      .where(Listing.status == "published", Listing.id != listing_id,
                             ListingEmbedding.model == visual.MODEL_NAME))
    scored = sorted(((float(np.frombuffer(vec, np.float32) @ query), other) for other, vec in rows),
                    key=lambda t: -t[0])[:max(1, min(limit, 20))]
    return {"items": [{**listing_out(db, other), "similarity": round(score, 3)} for score, other in scored]}


def waiting_size(db: Session, listing_id: int, size_id: int) -> ListingSize:
    size = db.get(ListingSize, size_id)
    listing = db.get(Listing, listing_id)
    if size is None or listing is None or size.listing_id != listing_id or listing.status not in ("published", "sold"):
        raise ApiError(404, "not_found")
    return size


@api.put("/listings/{listing_id}/sizes/{size_id}/alert")
def alert_when_back(listing_id: int, size_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Ask to be told when a sold-out size can be ordered again."""
    size = waiting_size(db, listing_id, size_id)
    if size.quantity > 0 and db.get(Listing, listing_id).status == "published":
        raise ApiError(409, "in_stock")
    if db.scalar(select(StockAlert.id).where(StockAlert.user_id == user.id, StockAlert.size_id == size.id)) is None:
        db.add(StockAlert(user_id=user.id, listing_id=listing_id, size_id=size.id))
        try:
            db.commit()
        except IntegrityError:  # a double tap
            db.rollback()
    return {"size_id": size.id, "alert": True}


@api.delete("/listings/{listing_id}/sizes/{size_id}/alert")
def cancel_stock_alert(listing_id: int, size_id: int, user: User = Depends(current_user),
                       db: Session = Depends(get_db)):
    for a in db.scalars(select(StockAlert).where(StockAlert.user_id == user.id, StockAlert.size_id == size_id,
                                                 StockAlert.listing_id == listing_id)).all():
        db.delete(a)
    db.commit()
    return {"size_id": size_id, "alert": False}


SUGGESTIONS = 8


def suggestion_keys(text: str) -> set[str]:
    """Forms a typed prefix may match: brand aliases mapped (найк -> nike) and plain transliteration (найк -> naik)."""
    return {normalize_query(text), transliterate(" ".join(text.lower().split()))}


def starts_a_word(key: str, typed: str) -> bool:
    return key.startswith(typed) or f" {typed}" in key


@api.get("/search/suggest")
def search_suggest(q: str = Query(default="", max_length=60), db: Session = Depends(get_db)):
    """Brands and models on sale now that start with what the buyer typed, the most offered first."""
    raw = " ".join(q.lower().split())
    typed = {t for t in suggestion_keys(q) if len(t) >= 2}
    if len(raw) >= 2:  # "най" is half of the alias "найк": suggest Nike before the word is finished
        typed |= {brand for alias, brand in BRAND_SYNONYMS.items() if alias.startswith(raw)}
    if not typed:
        return {"items": []}
    rows = db.execute(select(Listing.brand, Listing.model_name, func.count(Listing.id)).where(
        Listing.status == "published", Listing.brand.is_not(None)).group_by(Listing.brand, Listing.model_name)).all()
    brands: dict[str, int] = {}
    models: dict[str, int] = {}
    for brand, model, n in rows:
        brands[brand] = brands.get(brand, 0) + n
        if model:
            models[f"{brand} {model}"] = models.get(f"{brand} {model}", 0) + n
    found = []
    for kind, table in (("brand", brands), ("model", models)):
        hits = [(text, n) for text, n in table.items()
                if any(starts_a_word(k, t) for k in suggestion_keys(text) for t in typed)]
        found += [{"text": text, "kind": kind, "count": n} for text, n in sorted(hits, key=lambda h: (-h[1], h[0]))]
    return {"items": found[:SUGGESTIONS]}


@api.get("/listings/{listing_id}")
def get_listing(listing_id: int, user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    visible = listing is not None and (listing.status in ("published", "sold") or (user and listing.seller_id == user.id))
    if not visible:
        raise ApiError(404, "not_found")
    owner = bool(user and listing.seller_id == user.id)
    if not owner:
        db.execute(update(Listing).where(Listing.id == listing.id).values(views=Listing.views + 1))
        count_daily_view(db, listing.id)
        db.commit()
    alerts = [] if user is None else list(db.scalars(select(StockAlert.size_id).where(
        StockAlert.user_id == user.id, StockAlert.listing_id == listing.id)).all())
    return {**listing_out(db, listing, owner=owner), "size_fit": size_fit(db, listing), "stock_alerts": alerts}


ALMATY = timezone(timedelta(hours=5))  # Kazakhstan has one time zone, UTC+5, since March 2024


def count_daily_view(db: Session, listing_id: int) -> None:
    day = now_utc().astimezone(ALMATY).date()
    bump = (update(ListingDailyViews).where(ListingDailyViews.listing_id == listing_id, ListingDailyViews.day == day)
            .values(views=ListingDailyViews.views + 1))
    if db.execute(bump).rowcount:
        return
    try:
        with db.begin_nested():
            db.add(ListingDailyViews(listing_id=listing_id, day=day, views=1))
    except IntegrityError:  # another request created the row a moment ago
        db.execute(bump)


@api.get("/me/analytics")
def seller_analytics(days: int = 14, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Day-by-day views, orders and sales for the seller's listings, plus the listings that draw most interest."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    days = max(7, min(days, 90))
    today = now_utc().astimezone(ALMATY).date()
    first = today - timedelta(days=days - 1)
    listings = {l.id: l for l in db.scalars(select(Listing).where(Listing.seller_id == user.id))}
    per_day = {first + timedelta(days=i): {"views": 0, "orders": 0, "sold_tiyn": 0} for i in range(days)}
    views_by_listing: dict[int, int] = collections.Counter()
    if listings:
        for lid, day, views in db.execute(select(ListingDailyViews.listing_id, ListingDailyViews.day,
                                                 ListingDailyViews.views)
                                          .where(ListingDailyViews.listing_id.in_(listings),
                                                 ListingDailyViews.day >= first)):
            per_day[day]["views"] += views
            views_by_listing[lid] += views
    orders_by_listing: dict[int, int] = collections.Counter()
    since = datetime.combine(first, datetime.min.time(), ALMATY).astimezone(timezone.utc)
    for order in db.scalars(select(Order).where(Order.seller_id == user.id, Order.created_at >= since,
                                                Order.status != S.CANCELLED.value)):
        day = services.aware(order.created_at).astimezone(ALMATY).date()
        if day in per_day:
            per_day[day]["orders"] += 1
            if order.status == S.COMPLETED.value:
                per_day[day]["sold_tiyn"] += order.item_price_tiyn
        orders_by_listing[order.listing_id] += 1
    totals = {k: sum(d[k] for d in per_day.values()) for k in ("views", "orders", "sold_tiyn")}
    totals["conversion"] = round(totals["orders"] / totals["views"], 4) if totals["views"] else None
    top = sorted(listings.values(), key=lambda l: (-views_by_listing[l.id], -orders_by_listing[l.id], -l.id))[:5]
    return {
        "days": [{"date": d.isoformat(), **v} for d, v in per_day.items()],
        "totals": totals,
        "top": [{"id": l.id, "title": l.title, "status": l.status, "views": views_by_listing[l.id],
                 "orders": orders_by_listing[l.id]} for l in top if views_by_listing[l.id] or orders_by_listing[l.id]],
    }


# ---------------------------------------------------------------- saved searches
MAX_SAVED_SEARCHES = 10
SEARCH_FIELDS = ("q", "category", "brand", "condition", "min_price_tiyn", "max_price_tiyn", "size_cm")


class SavedSearchIn(BaseModel):
    q: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=30)
    brand: str | None = Field(default=None, max_length=60)
    condition: str | None = Field(default=None, max_length=200)
    min_price_tiyn: int | None = Field(default=None, ge=0)
    max_price_tiyn: int | None = Field(default=None, ge=0)
    size_cm: str | None = Field(default=None, max_length=8)


def search_values(source) -> dict:
    values = {f: getattr(source, f) for f in SEARCH_FIELDS}
    return {k: (v.strip() or None) if isinstance(v, str) else v for k, v in values.items()}


def saved_search_out(s: SavedSearch) -> dict:
    return {"id": s.id, **search_values(s), "created_at": services.aware(s.created_at).isoformat()}


def announce(db: Session, listing: Listing) -> None:
    """Tell the shop's followers and buyers whose saved searches match a listing, once, when it first goes on sale."""
    if listing.announced_at is not None:
        return
    listing.announced_at = now_utc()
    db.flush()
    told: set[int] = {listing.seller_id}
    price = promo.format_tenge(listing.price_tiyn)
    seller = db.get(User, listing.seller_id)
    shop = seller.shop_name or "VITRINA"
    for follower in db.scalars(select(Follow.user_id).join(User, User.id == Follow.user_id).where(
            Follow.seller_id == listing.seller_id, User.is_blocked.is_(False)).order_by(Follow.id)).all():
        if follower not in told:
            told.add(follower)  # a follower who also has a matching saved search hears about it once
            services.notify(db, follower, "followed_shop", f"«{shop}» жаңа тауар қойды: «{listing.title}», {price}",
                            f"«{shop}» выставил новый товар: «{listing.title}», {price}", listing_id=listing.id)
    for saved in db.scalars(select(SavedSearch).join(User, User.id == SavedSearch.user_id).where(
            User.is_blocked.is_(False)).order_by(SavedSearch.id)).all():
        if saved.user_id in told:
            continue
        match = catalog_filter(select(Listing.id).where(Listing.id == listing.id), **search_values(saved))
        if db.scalar(match) is not None:
            told.add(saved.user_id)
            services.notify(db, saved.user_id, "saved_search", f"Іздеуіңізге сай жаңа тауар: «{listing.title}», {price}",
                            f"Новый товар по вашему поиску: «{listing.title}», {price}", listing_id=listing.id)


@api.post("/saved-searches", status_code=201)
def save_search(body: SavedSearchIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    values = search_values(body)
    if not any(v is not None for v in values.values()):
        raise ApiError(422, "validation", "a saved search needs at least one filter")
    if values["size_cm"]:
        cm_to_mm(values["size_cm"])  # same validation as the catalog
    mine = db.scalars(select(SavedSearch).where(SavedSearch.user_id == user.id)).all()
    same = next((s for s in mine if search_values(s) == values), None)
    if same:
        return saved_search_out(same)
    if len(mine) >= MAX_SAVED_SEARCHES:
        raise ApiError(409, "saved_search_limit")
    saved = SavedSearch(user_id=user.id, **values)
    db.add(saved)
    db.commit()
    return saved_search_out(saved)


@api.get("/saved-searches")
def list_saved_searches(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(SavedSearch).where(SavedSearch.user_id == user.id).order_by(SavedSearch.id.desc())).all()
    return {"items": [saved_search_out(s) for s in rows]}


@api.delete("/saved-searches/{search_id}", status_code=204)
def delete_saved_search(search_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    saved = db.get(SavedSearch, search_id)
    if saved is None or saved.user_id != user.id:
        raise ApiError(404, "not_found")
    db.delete(saved)
    db.commit()


@api.post("/favorites/{listing_id}", status_code=204)
def add_favorite(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if db.get(Listing, listing_id) is None:
        raise ApiError(404, "not_found")
    db.add(Favorite(user_id=user.id, listing_id=listing_id))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()


@api.delete("/favorites/{listing_id}", status_code=204)
def remove_favorite(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    fav = db.scalar(select(Favorite).where(Favorite.user_id == user.id, Favorite.listing_id == listing_id))
    if fav:
        db.delete(fav)
        db.commit()


@api.get("/favorites")
def list_favorites(user: User = Depends(current_user), db: Session = Depends(get_db)):
    ids = db.scalars(select(Favorite.listing_id).where(Favorite.user_id == user.id)).all()
    return {"items": [listing_out(db, db.get(Listing, i)) for i in ids]}


# ---------------------------------------------------------------- orders
def order_for(db: Session, order_id: int, user: User, *, role: str | None = None) -> Order:
    """Returns 404 (not 403) for orders the user is not part of, so ids leak nothing."""
    order = db.get(Order, order_id)
    if order is None:
        raise ApiError(404, "not_found")
    is_party = user.id in (order.buyer_id, order.seller_id)
    if role == "buyer" and user.id != order.buyer_id or role == "seller" and user.id != order.seller_id:
        raise ApiError(404, "not_found")
    if role is None and not is_party and user.role not in ("support", "admin"):
        raise ApiError(404, "not_found")
    return order


def clean_delivery(body: DeliveryIn) -> dict:
    phone = re.sub(r"[\s()\-]", "", body.recipient_phone)
    if phone.startswith("8") and len(phone) == 11:
        phone = "+7" + phone[1:]
    if not PHONE_RE.match(phone):
        raise ApiError(422, "invalid_phone")
    values = {"recipient_name": body.recipient_name.strip(), "recipient_phone": phone, "city": body.city.strip(),
              "address": body.address.strip(), "note": (body.note or "").strip() or None}
    if len(values["recipient_name"]) < 2 or len(values["city"]) < 2 or len(values["address"]) < 5:
        raise ApiError(422, "validation", "delivery fields are required")
    return values


@api.post("/orders", status_code=201)
def create_order(body: OrderIn, user: User = Depends(current_user), db: Session = Depends(get_db),
                 cfg: Settings = Depends(get_settings), idempotency_key: str | None = Header(default=None)):
    if not idempotency_key:
        raise ApiError(400, "idempotency_key_required")
    seen = db.scalar(select(IdempotencyRecord).where(IdempotencyRecord.user_id == user.id,
                                                     IdempotencyRecord.scope == "create_order",
                                                     IdempotencyRecord.key == idempotency_key))
    if seen:
        return order_out(db.get(Order, seen.order_id))
    listing = db.get(Listing, body.listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    if away_until(db.get(User, listing.seller_id)):
        raise ApiError(409, "seller_away")
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    delivery = clean_delivery(body.delivery)
    offer = offers.offer_for_order(db, body.offer_id, user, listing, body.size_id) if body.offer_id else None
    size = db.scalar(select(ListingSize).where(ListingSize.id == body.size_id,
                                               ListingSize.listing_id == listing.id).with_for_update())
    if size is None or size.quantity <= 0:
        raise ApiError(409, "out_of_stock")
    # The listing may have got cheaper than the offer since; the buyer always pays the lower.
    price = min(listing.price_tiyn, offers.price(offer)) if offer else listing.price_tiyn
    promo, off = None, 0
    if body.promo_code:
        if offer:
            raise ApiError(409, "promo_with_offer")
        promo, off = coupons.apply(db, body.promo_code, listing, price, user, lock=True)
    size.quantity -= 1
    if not any(s.quantity > 0 for s in listing.sizes):
        listing.status = "sold"
    order = Order(buyer_id=user.id, seller_id=listing.seller_id, listing_id=listing.id, size_id=size.id,
                  status=S.CREATED.value, item_price_tiyn=price - off,
                  promo_code_id=promo.id if promo else None, promo_code=promo.code if promo else None,
                  promo_discount_tiyn=off,
                  delivery_price_tiyn=listing.delivery_price_tiyn, commission_version=cfg.commission.version,
                  recipient_name=delivery["recipient_name"], recipient_phone=delivery["recipient_phone"],
                  delivery_city=delivery["city"], delivery_address=delivery["address"],
                  delivery_note=delivery["note"])
    user.last_delivery = json.dumps(delivery, ensure_ascii=False)
    db.add(order)
    db.flush()
    if offer:
        offer.status, offer.order_id = "ordered", order.id
    db.add(IdempotencyRecord(user_id=user.id, scope="create_order", key=idempotency_key, order_id=order.id))
    db.commit()
    return order_out(order)


@api.get("/orders")
def list_orders(role: Literal["buyer", "seller"] = "buyer", user: User = Depends(current_user),
                db: Session = Depends(get_db)):
    column = Order.buyer_id if role == "buyer" else Order.seller_id
    rows = db.scalars(select(Order).where(column == user.id).order_by(Order.id.desc()).limit(100)).all()
    return {"items": [order_summary(db, o) for o in rows]}


@api.get("/orders/{order_id}")
def get_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user)
    reviewed = db.scalar(select(Review.id).where(Review.order_id == order.id)) is not None
    events = db.scalars(select(OrderEvent).where(OrderEvent.order_id == order.id).order_by(OrderEvent.id)).all()
    return {**order_summary(db, order), "reviewed": reviewed, "delivery": delivery_out(order, user),
            "history": [{"status": e.to_status, "at": services.aware(e.at).isoformat()} for e in events]}


@api.post("/orders/{order_id}/pay")
def start_payment(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer")
    if order.status == S.CREATED.value:
        services.move(db, order, S.PAYMENT_PENDING, Actor.BUYER, user_id=user.id)
        db.commit()
    elif order.status != S.PAYMENT_PENDING.value:
        raise ApiError(409, "invalid_status")
    # Sandbox only: a real provider returns its own payment form/session here.
    return {"provider": "sandbox", "order_id": order.id, "amount_tiyn": services.total_tiyn(order), "currency": "KZT"}


@api.post("/orders/{order_id}/cancel")
def cancel_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer")
    if order.status in (S.CREATED.value, S.PAYMENT_PENDING.value):
        services.move(db, order, S.CANCELLED, Actor.BUYER, user_id=user.id)
    else:  # once paid, cancelling means a full refund through the provider
        services.move(db, order, S.REFUND_PENDING, Actor.BUYER, user_id=user.id, reason="buyer cancelled")
        order.pending_refund_tiyn = services.total_tiyn(order)
    services.restock(db, order)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/decline")
def decline_order(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller")
    services.move(db, order, S.REFUND_PENDING, Actor.SELLER, user_id=user.id, reason=body.reason)
    order.pending_refund_tiyn = services.total_tiyn(order)
    services.restock(db, order)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/accept")
def accept_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller")
    services.move(db, order, S.SELLER_ACCEPTED, Actor.SELLER, user_id=user.id)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/ship")
def ship_order(order_id: int, body: ShipIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller")
    services.move(db, order, S.SHIPPED, Actor.SELLER, user_id=user.id, tracking_number=body.tracking_number)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/confirm")
def confirm_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
                  cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, user, role="buyer")
    services.move(db, order, S.COMPLETED, Actor.BUYER, user_id=user.id)
    services.settle(db, order, refund_tiyn=0, rule=cfg.commission, actor=f"buyer:{user.id}")
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/dispute")
def open_dispute(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    services.move(db, order, S.DISPUTED, Actor.BUYER, user_id=user.id, reason=body.reason)
    order.dispute_reason = body.reason
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/return")
def request_return(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    services.move(db, order, S.RETURN_REQUESTED, Actor.BUYER, user_id=user.id, reason=body.reason)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/approve-return")
def approve_return(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller")
    services.move(db, order, S.REFUND_PENDING, Actor.SELLER, user_id=user.id, reason="seller approved return")
    order.pending_refund_tiyn = services.total_tiyn(order)
    db.commit()
    return order_out(order)


# ---------------------------------------------------------------- staff
@api.post("/admin/orders/{order_id}/resolve")
def resolve_dispute(order_id: int, body: ResolveIn, staff: User = Depends(staff_user),
                    db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, staff)
    if body.refund_tiyn > services.total_tiyn(order):
        raise ApiError(422, "validation", "refund exceeds the order total")
    if body.refund_tiyn == 0:
        services.move(db, order, S.COMPLETED, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
        services.settle(db, order, refund_tiyn=0, rule=cfg.commission, actor=f"support:{staff.id}", reason=body.reason)
    else:
        services.move(db, order, S.REFUND_PENDING, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
        order.pending_refund_tiyn = body.refund_tiyn
    services.audit(db, staff.id, "resolve_dispute", f"order:{order.id}", f"refund={body.refund_tiyn}; {body.reason}")
    db.commit()
    return order_out(order)


@api.post("/admin/listings/{listing_id}/hide")
def hide_listing(listing_id: int, body: ReasonIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    listing.status = "hidden"
    services.audit(db, staff.id, "hide_listing", f"listing:{listing.id}", body.reason)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.get("/admin/overview")
def admin_overview(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    orders = dict(db.execute(select(Order.status, func.count(Order.id)).group_by(Order.status)).all())
    listings = dict(db.execute(select(Listing.status, func.count(Listing.id)).group_by(Listing.status)).all())
    gmv = db.scalar(select(func.coalesce(func.sum(Order.item_price_tiyn), 0)).where(Order.status == S.COMPLETED.value))
    return {"orders": orders, "listings": listings, "completed_item_value_tiyn": int(gmv or 0),
            "users": db.scalar(select(func.count(User.id))), "sellers": db.scalar(
                select(func.count(User.id)).where(User.is_seller.is_(True)))}


@api.get("/admin/orders")
def admin_orders(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Order).order_by(Order.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Order.status == status)
    items = []
    for o in db.scalars(stmt).all():
        events = db.scalars(select(OrderEvent).where(OrderEvent.order_id == o.id).order_by(OrderEvent.id)).all()
        items.append({**order_summary(db, o), "history": [
            {"status": e.to_status, "actor": e.actor, "reason": e.reason, "at": services.aware(e.at).isoformat()}
            for e in events]})
    return {"items": items}


@api.get("/admin/listings")
def admin_listings(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Listing).order_by(Listing.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Listing.status == status)
    return {"items": [listing_out(db, r) for r in db.scalars(stmt).all()]}


@api.get("/admin/moderation")
def admin_moderation(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Listings the publish checks flagged, oldest first so nobody waits longest."""
    rows = db.scalars(select(Listing).where(Listing.status == "moderation").order_by(Listing.id)).all()
    return {"items": [{"listing": listing_out(db, r), "moderation": moderation_out(r)} for r in rows]}


class ModerationRejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=2000)


def queued_listing(db: Session, listing_id: int) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    if listing.status != "moderation":
        raise ApiError(409, "invalid_status")
    return listing


@api.post("/admin/moderation/{listing_id}/approve")
def approve_listing(listing_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    listing = queued_listing(db, listing_id)
    listing.status = "published"
    # Remember what was cleared so pausing and republishing does not queue the same listing again.
    listing.moderation_cleared = ",".join(sorted(set(split_codes(listing.moderation_cleared))
                                                 | set(split_codes(listing.moderation_flags)))) or None
    listing.moderation_note = None
    announce(db, listing)
    services.audit(db, staff.id, "approve_listing", f"listing:{listing.id}", listing.moderation_flags or "")
    services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» тексеруден өтті және сатылымда.",
                    f"«{listing.title}» прошёл проверку и уже продаётся.", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.post("/admin/moderation/{listing_id}/reject")
def reject_listing(listing_id: int, body: ModerationRejectIn, staff: User = Depends(staff_user),
                   db: Session = Depends(get_db)):
    listing = queued_listing(db, listing_id)
    reason = body.reason.strip()
    listing.status, listing.moderation_note = "rejected", reason
    services.audit(db, staff.id, "reject_listing", f"listing:{listing.id}", reason)
    services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» қайтарылды: {reason}",
                    f"«{listing.title}» возвращён: {reason}", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.get("/admin/reports")
def admin_reports(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Open reports grouped by listing, most-reported first."""
    rows = db.scalars(select(ListingReport).where(ListingReport.status == "open").order_by(ListingReport.id)).all()
    by_listing: dict[int, list[ListingReport]] = {}
    for r in rows:
        by_listing.setdefault(r.listing_id, []).append(r)
    items = [{"listing": listing_out(db, db.get(Listing, lid)),
              "reports": [{"id": r.id, "reason": r.reason, "text": r.text, "reporter_id": r.reporter_id,
                           "at": services.aware(r.created_at).isoformat()} for r in reports]}
             for lid, reports in by_listing.items()]
    items.sort(key=lambda i: -len(i["reports"]))
    return {"items": items}


@api.post("/admin/reports/{listing_id}/close")
def close_reports(listing_id: int, body: ReportCloseIn, staff: User = Depends(staff_user),
                  db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    reports = db.scalars(select(ListingReport).where(ListingReport.listing_id == listing_id,
                                                     ListingReport.status == "open")).all()
    if listing is None or not reports:
        raise ApiError(404, "not_found")
    outcome = "hidden" if body.action == "hide" else "dismissed"
    for r in reports:
        r.status = outcome
    if body.action == "hide":
        listing.status = "hidden"
        services.notify(db, listing.seller_id, "listing_hidden",
                        f"«{listing.title}» модератор шешімімен жасырылды: {body.reason}",
                        f"«{listing.title}» скрыт по решению модератора: {body.reason}")
    for reporter in {r.reporter_id for r in reports}:
        services.notify(db, reporter, "report_closed",
                        f"«{listing.title}» туралы шағымыңыз қаралды: "
                        + ("тауар жасырылды." if body.action == "hide" else "бұзушылық табылмады."),
                        f"Ваша жалоба на «{listing.title}» рассмотрена: "
                        + ("товар скрыт." if body.action == "hide" else "нарушений не найдено."))
    services.audit(db, staff.id, f"reports_{outcome}", f"listing:{listing.id}", body.reason)
    db.commit()
    return {"listing_id": listing.id, "status": listing.status, "closed": len(reports)}


@api.get("/admin/audit")
def admin_audit(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(AuditLog).order_by(AuditLog.id.desc()).limit(100)).all()
    return {"items": [{"actor_user_id": r.actor_user_id, "action": r.action, "target": r.target, "reason": r.reason,
                       "at": services.aware(r.at).isoformat()} for r in rows]}


@api.get("/admin/orders/{order_id}/ledger")
def order_ledger(order_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    from .models import LedgerTx
    txs = db.scalars(select(LedgerTx).where(LedgerTx.order_id == order_id).order_by(LedgerTx.id)).all()
    return {"transactions": [{"kind": t.kind, "actor": t.actor, "reason": t.reason,
                              "entries": [{"account": e.account, "debit": e.debit, "credit": e.credit} for e in t.entries]}
                             for t in txs]}


# ---------------------------------------------------------------- webhooks (provider -> us)
async def verified_event(request: Request, secret: bytes) -> dict:
    body = await request.body()
    try:
        ts = int(request.headers.get("X-Timestamp", "0"))
        verify(secret, ts, body, request.headers.get("X-Signature", ""))
        return json.loads(body)
    except (WebhookRejected, ValueError) as exc:
        raise ApiError(401, "bad_signature", str(exc)) from exc


def first_time(db: Session, source: str, event_id: str) -> bool:
    db.add(WebhookEvent(source=source, event_id=event_id))
    try:
        db.flush()
        return True
    except IntegrityError:
        db.rollback()
        return False


hooks = APIRouter(prefix="/api/v1/webhooks")


@hooks.post("/payments/sandbox")
async def payment_webhook(request: Request, db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    event = await verified_event(request, cfg.payment_webhook_secret)
    try:
        event_id, kind, order_id = str(event["id"]), event["type"], int(event["order_id"])
        amount, currency = event["amount_tiyn"], event["currency"]
    except (KeyError, TypeError, ValueError) as exc:
        raise ApiError(422, "validation", f"malformed event: {exc}") from exc
    order = db.get(Order, order_id)
    if order is None:
        raise ApiError(404, "not_found")
    if not first_time(db, "payments", event_id):
        return {"result": "duplicate"}
    if kind == "payment.succeeded":
        if amount != services.total_tiyn(order) or currency != "KZT":
            db.rollback()
            raise ApiError(409, "amount_mismatch")
        if order.status != S.PAYMENT_PENDING.value:
            db.commit()
            return {"result": "duplicate"}
        services.record_payment(db, order, event_id)
        services.move(db, order, S.PAID, Actor.SYSTEM)
    elif kind == "refund.succeeded":
        if order.status != S.REFUND_PENDING.value or amount != order.pending_refund_tiyn:
            db.rollback()
            raise ApiError(409, "amount_mismatch")
        services.move(db, order, S.REFUNDED, Actor.SYSTEM)
        services.settle(db, order, refund_tiyn=amount, rule=cfg.commission, actor="system")
    db.commit()
    return {"result": "applied", "status": order.status}


@hooks.post("/delivery/sandbox")
async def delivery_webhook(request: Request, db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    event = await verified_event(request, cfg.delivery_webhook_secret)
    order = db.scalar(select(Order).where(Order.tracking_number == str(event.get("tracking_number", ""))))
    if order is None:
        raise ApiError(404, "not_found")
    if not first_time(db, "delivery", str(event.get("id"))):
        return {"result": "duplicate"}
    target = {"delivery.in_transit": S.IN_TRANSIT, "delivery.delivered": S.DELIVERED_PENDING_CONFIRMATION}.get(event.get("type"))
    if target is None:
        db.commit()
        return {"result": "ignored"}
    services.move(db, order, target, Actor.SYSTEM)
    db.commit()
    return {"result": "applied", "status": order.status}


# ---------------------------------------------------------------- app
def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    app = FastAPI(title="VITRINA API", version="0.1.0")
    app.state.settings = settings
    app.state.sessions = make_session_factory(settings.database_url, create_schema=settings.auto_create_schema)
    app.state.storage = LocalStorage(settings.media_dir, settings.public_media_url)
    app.state.segmenter = cutout.load_segmenter(settings.cutout_model)
    app.state.embedder = visual.load_embedder(settings.search_model)
    app.state.image_search_limiter = SlidingWindowLimiter(IMAGE_SEARCH_PER_MINUTE, 60)
    app.add_exception_handler(ApiError, api_error_handler)

    async def validation_handler(request: Request, exc: RequestValidationError):
        return await api_error_handler(request, ApiError(422, "validation", str(exc.errors()[:3])))

    app.add_exception_handler(RequestValidationError, validation_handler)
    app.include_router(api)
    app.include_router(hooks)
    app.include_router(social_router)
    app.include_router(share_router)
    app.include_router(offers.router)
    app.include_router(authenticity.router)
    app.include_router(coupons.router)
    app.include_router(qa.router)
    # Development only: serve uploaded photos from disk. Production serves them from the bucket/CDN.
    app.mount("/media", StaticFiles(directory=settings.media_dir), name="media")
    # Support console: a static page that talks to the same staff-only API; the page itself holds no data.
    app.mount("/admin", StaticFiles(directory=Path(__file__).parent / "admin", html=True), name="admin")
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"],
                           allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])
    return app
