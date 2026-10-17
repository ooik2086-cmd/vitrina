"""VITRINA API v1 (modular monolith). Run: uvicorn vitrina_api.app:create_app --factory --reload"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Depends, FastAPI, File, Header, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import Authenticity, Condition, compute_bounds, normalize_query
from vitrina_core.orders import Actor, OrderStatus as S
from vitrina_core.webhooks import WebhookRejected, verify

from . import services
from . import cutout, visual
from .config import Settings
from .deps import current_user, get_db, get_settings, get_storage, now_utc, optional_user, sha256, staff_user
from .errors import ApiError, api_error_handler
from .social import router as social_router, seller_rating
from .models import (AuditLog, ListingEmbedding, ListingReport, AuthToken, Favorite, IdempotencyRecord, Listing, ListingSize, Media, Order, OrderEvent,
                     OtpCode, Review, User, WebhookEvent, make_session_factory)
from .storage import MAX_UPLOAD_BYTES, LocalStorage, normalize_image

CATEGORIES = ("sneakers", "sport", "casual", "classic", "boots_winter", "sandals", "kids", "other")
PHONE_RE = re.compile(r"^\+7\d{10}$")
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


class OrderIn(BaseModel):
    listing_id: int
    size_id: int


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


def listing_out(db: Session, listing: Listing, *, owner: bool = False) -> dict:
    """owner=True adds stock counts, which only the seller sees."""
    seller = db.get(User, listing.seller_id)
    return {
        "id": listing.id, "status": listing.status, "title": listing.title, "category": listing.category,
        "brand": listing.brand, "model_name": listing.model_name, "color": listing.color,
        "price_tiyn": listing.price_tiyn, "delivery_price_tiyn": listing.delivery_price_tiyn,
        # Three separate facts, never merged into one "quality" label.
        "segment": segment_for(db, listing), "condition": listing.condition, "authenticity": listing.authenticity,
        "defects": listing.defects, "description": listing.description, "showcase_style": listing.showcase_style,
        "sizes": [{"id": s.id, "label": s.label, "insole_cm": mm_to_cm(s.insole_mm), "available": s.quantity > 0,
                   **({"quantity": s.quantity} if owner else {})} for s in listing.sizes],
        "media": [{"original_url": m.original_url, "processed_url": m.processed_url, "angle": m.angle}
                  for m in listing.media],
        "seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,  # never the phone
                   **seller_rating(db, seller.id)},
    }


def order_out(order: Order) -> dict:
    return {
        "id": order.id, "status": order.status, "listing_id": order.listing_id, "size_id": order.size_id,
        "buyer_id": order.buyer_id, "seller_id": order.seller_id,
        "item_price_tiyn": order.item_price_tiyn, "delivery_price_tiyn": order.delivery_price_tiyn,
        "total_tiyn": services.total_tiyn(order), "tracking_number": order.tracking_number,
        "delivered_at": services.aware(order.delivered_at).isoformat() if order.delivered_at else None,
    }


def order_summary(db: Session, order: Order) -> dict:
    """Order plus what a list row needs to be recognisable: the item's title, size and photo."""
    listing = db.get(Listing, order.listing_id)
    size = db.get(ListingSize, order.size_id)
    cover = next((m.processed_url or m.original_url for m in listing.media if m.angle != "frame"), None)
    return {**order_out(order), "listing_title": listing.title, "listing_cover": cover,
            "size_label": size.label, "size_cm": mm_to_cm(size.insole_mm)}


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
                    cfg: Settings = Depends(get_settings)):
    listing = own_listing(db, listing_id, user)
    # "hidden" is a moderation decision; only staff can lift it.
    if listing.status not in ("draft", "paused"):
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
    return listing_out(db, listing, owner=True)


@api.patch("/listings/{listing_id}")
def edit_listing(listing_id: int, body: ListingPatch, user: User = Depends(current_user),
                 db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    if body.price_tiyn is not None:
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
    db.commit()
    return listing_out(db, listing, owner=True)


@api.post("/listings/{listing_id}/pause")
def pause_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status != "published":
        raise ApiError(409, "invalid_status")
    listing.status = "paused"
    db.commit()
    return listing_out(db, listing, owner=True)


@api.get("/listings")
def search_listings(q: str | None = None, category: str | None = None, brand: str | None = None,
                    condition: str | None = None, min_price_tiyn: int | None = None,
                    max_price_tiyn: int | None = None, size_cm: str | None = None,
                    sort: Literal["new", "price_asc", "price_desc"] = "new", seller_id: int | None = None,
                    limit: int = 20, offset: int = 0, db: Session = Depends(get_db)):
    stmt = select(Listing).where(Listing.status == "published")
    if q:
        for token in normalize_query(q).split():
            stmt = stmt.where(Listing.search_text.contains(token))
    if category:
        stmt = stmt.where(Listing.category == category)
    if seller_id is not None:
        stmt = stmt.where(Listing.seller_id == seller_id)
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


@api.get("/sellers/{seller_id}")
def seller_profile(seller_id: int, db: Session = Depends(get_db)):
    """Public shop card. Counts come from the platform's own records, not from what the seller typed."""
    seller = db.get(User, seller_id)
    if seller is None or not seller.is_seller or seller.is_blocked:
        raise ApiError(404, "not_found")
    sales = db.scalar(select(func.count(Order.id)).where(Order.seller_id == seller.id,
                                                         Order.status == S.COMPLETED.value))
    live = db.scalar(select(func.count(Listing.id)).where(Listing.seller_id == seller.id,
                                                          Listing.status == "published"))
    return {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
            "since": services.aware(seller.created_at).date().isoformat(),
            "completed_sales": int(sales or 0), "listings": int(live or 0), **seller_rating(db, seller.id)}


@api.post("/search/image")
async def search_by_image(request: Request, file: UploadFile = File(...), category: str | None = None,
                          size_cm: str | None = None, limit: int = 20, db: Session = Depends(get_db)):
    """Listings that look like the uploaded photo, most similar first. The photo is not stored."""
    embed = request.app.state.embedder
    if embed is None:
        raise ApiError(503, "image_search_off")
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
    return {**order_summary(db, order), "reviewed": reviewed,
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
                        f"«{listing.title}» модератор шешімімен жасырылды: {body.reason}")
    for reporter in {r.reporter_id for r in reports}:
        services.notify(db, reporter, "report_closed",
                        f"«{listing.title}» туралы шағымыңыз қаралды: "
                        + ("тауар жасырылды." if body.action == "hide" else "бұзушылық табылмады."))
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
    app.add_exception_handler(ApiError, api_error_handler)

    async def validation_handler(request: Request, exc: RequestValidationError):
        return await api_error_handler(request, ApiError(422, "validation", str(exc.errors()[:3])))

    app.add_exception_handler(RequestValidationError, validation_handler)
    app.include_router(api)
    app.include_router(hooks)
    app.include_router(social_router)
    # Development only: serve uploaded photos from disk. Production serves them from the bucket/CDN.
    app.mount("/media", StaticFiles(directory=settings.media_dir), name="media")
    # Support console: a static page that talks to the same staff-only API; the page itself holds no data.
    app.mount("/admin", StaticFiles(directory=Path(__file__).parent / "admin", html=True), name="admin")
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"],
                           allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])
    return app
