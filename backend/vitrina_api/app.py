"""VITRINA API v1 (modular monolith). Run: uvicorn vitrina_api.app:create_app --factory --reload"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from typing import Literal

from fastapi import APIRouter, Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import Authenticity, Condition, compute_bounds, normalize_query
from vitrina_core.orders import Actor, OrderStatus as S
from vitrina_core.webhooks import WebhookRejected, verify

from . import services
from .config import Settings
from .errors import ApiError, api_error_handler
from .models import (AuthToken, Favorite, IdempotencyRecord, Listing, ListingSize, Media, Order, OtpCode, User,
                     WebhookEvent, make_session_factory)

CATEGORIES = ("sneakers", "sport", "casual", "classic", "boots_winter", "sandals", "kids", "other")
PHONE_RE = re.compile(r"^\+7\d{10}$")
DEFECT_REQUIRED = {Condition.USED_GOOD.value, Condition.DEFECTIVE.value}


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


# ---------------------------------------------------------------- dependencies
def get_db(request: Request):
    db = request.app.state.sessions()
    try:
        yield db
    finally:
        db.close()


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def current_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User:
    if not authorization or not authorization.startswith("Bearer "):
        raise ApiError(401, "unauthorized")
    token = db.scalar(select(AuthToken).where(AuthToken.token_hash == sha256(authorization[7:].strip())))
    if token is None or token.revoked or services.aware(token.expires_at) < now_utc():
        raise ApiError(401, "unauthorized")
    user = db.get(User, token.user_id)
    if user.is_blocked:
        raise ApiError(403, "forbidden", "account blocked")
    return user


def optional_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User | None:
    if not authorization:
        return None
    return current_user(authorization, db)


def staff_user(user: User = Depends(current_user)) -> User:
    if user.role not in ("support", "admin"):
        raise ApiError(403, "forbidden")
    return user


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


class OrderIn(BaseModel):
    listing_id: int
    size_id: int


class ShipIn(BaseModel):
    tracking_number: str = Field(max_length=60)


class ReasonIn(BaseModel):
    reason: str = Field(max_length=2000)


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


def listing_out(db: Session, listing: Listing) -> dict:
    seller = db.get(User, listing.seller_id)
    return {
        "id": listing.id, "status": listing.status, "title": listing.title, "category": listing.category,
        "brand": listing.brand, "model_name": listing.model_name, "color": listing.color,
        "price_tiyn": listing.price_tiyn, "delivery_price_tiyn": listing.delivery_price_tiyn,
        # Three separate facts, never merged into one "quality" label.
        "segment": segment_for(db, listing), "condition": listing.condition, "authenticity": listing.authenticity,
        "defects": listing.defects, "description": listing.description, "showcase_style": listing.showcase_style,
        "sizes": [{"id": s.id, "label": s.label, "insole_cm": mm_to_cm(s.insole_mm), "available": s.quantity > 0}
                  for s in listing.sizes],
        "media": [{"original_url": m.original_url, "processed_url": m.processed_url, "angle": m.angle}
                  for m in listing.media],
        "seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city},  # never the phone
    }


def order_out(order: Order) -> dict:
    return {
        "id": order.id, "status": order.status, "listing_id": order.listing_id, "size_id": order.size_id,
        "buyer_id": order.buyer_id, "seller_id": order.seller_id,
        "item_price_tiyn": order.item_price_tiyn, "delivery_price_tiyn": order.delivery_price_tiyn,
        "total_tiyn": services.total_tiyn(order), "tracking_number": order.tracking_number,
        "delivered_at": services.aware(order.delivered_at).isoformat() if order.delivered_at else None,
    }


def me_out(user: User) -> dict:
    return {"id": user.id, "phone": user.phone, "display_name": user.display_name, "city": user.city,
            "is_seller": user.is_seller, "shop_name": user.shop_name, "role": user.role}


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


@api.patch("/me")
def patch_me(body: ProfilePatch, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user = db.merge(user)
    for k, v in body.model_dump(exclude_unset=True).items():
        setattr(user, k, v)
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


@api.post("/listings", status_code=201)
def create_listing(body: ListingIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not user.is_seller:
        raise ApiError(403, "seller_required")
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
    return listing_out(db, listing)


def own_listing(db: Session, listing_id: int, user: User) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None or listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    return listing


@api.post("/listings/{listing_id}/publish")
def publish_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
                    cfg: Settings = Depends(get_settings)):
    listing = own_listing(db, listing_id, user)
    if listing.status not in ("draft", "hidden"):
        raise ApiError(409, "invalid_status")
    if len(listing.media) < cfg.min_listing_photos:
        raise ApiError(422, "missing_required_photos")
    if listing.condition in DEFECT_REQUIRED and not (listing.defects or "").strip():
        raise ApiError(422, "defects_required")
    if listing.condition == Condition.DEFECTIVE.value and not any(m.angle == "defect" for m in listing.media):
        raise ApiError(422, "defects_required", "a close-up photo of each defect is required")
    if not any(s.quantity > 0 for s in listing.sizes):
        raise ApiError(422, "out_of_stock")
    # TODO(moderation): route to "moderation" when automated checks flag the listing.
    listing.status = "published"
    db.commit()
    return listing_out(db, listing)


@api.get("/listings")
def search_listings(q: str | None = None, category: str | None = None, brand: str | None = None,
                    condition: str | None = None, min_price_tiyn: int | None = None,
                    max_price_tiyn: int | None = None, size_cm: str | None = None,
                    limit: int = 20, offset: int = 0, db: Session = Depends(get_db)):
    stmt = select(Listing).where(Listing.status == "published")
    if q:
        for token in normalize_query(q).split():
            stmt = stmt.where(Listing.search_text.contains(token))
    if category:
        stmt = stmt.where(Listing.category == category)
    if brand:
        stmt = stmt.where(Listing.search_text.contains(normalize_query(brand)))
    if condition:
        stmt = stmt.where(Listing.condition == condition)
    if min_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn >= min_price_tiyn)
    if max_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn <= max_price_tiyn)
    if size_cm:
        mm = cm_to_mm(size_cm)
        stmt = stmt.where(Listing.id.in_(select(ListingSize.listing_id).where(
            ListingSize.quantity > 0, ListingSize.insole_mm.between(mm - 5, mm + 5))))
    rows = db.scalars(stmt.order_by(Listing.id.desc()).limit(min(limit, 50)).offset(offset)).all()
    return {"items": [listing_out(db, r) for r in rows]}


@api.get("/listings/{listing_id}")
def get_listing(listing_id: int, user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    visible = listing is not None and (listing.status in ("published", "sold") or (user and listing.seller_id == user.id))
    if not visible:
        raise ApiError(404, "not_found")
    return listing_out(db, listing)


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
    size = db.scalar(select(ListingSize).where(ListingSize.id == body.size_id,
                                               ListingSize.listing_id == listing.id).with_for_update())
    if size is None or size.quantity <= 0:
        raise ApiError(409, "out_of_stock")
    size.quantity -= 1
    if not any(s.quantity > 0 for s in listing.sizes):
        listing.status = "sold"
    order = Order(buyer_id=user.id, seller_id=listing.seller_id, listing_id=listing.id, size_id=size.id,
                  status=S.CREATED.value, item_price_tiyn=listing.price_tiyn,
                  delivery_price_tiyn=listing.delivery_price_tiyn, commission_version=cfg.commission.version)
    db.add(order)
    db.flush()
    db.add(IdempotencyRecord(user_id=user.id, scope="create_order", key=idempotency_key, order_id=order.id))
    db.commit()
    return order_out(order)


@api.get("/orders/{order_id}")
def get_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    return order_out(order_for(db, order_id, user))


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
    app.state.sessions = make_session_factory(settings.database_url)
    app.add_exception_handler(ApiError, api_error_handler)

    async def validation_handler(request: Request, exc: RequestValidationError):
        return await api_error_handler(request, ApiError(422, "validation", str(exc.errors()[:3])))

    app.add_exception_handler(RequestValidationError, validation_handler)
    app.include_router(api)
    app.include_router(hooks)
    return app
