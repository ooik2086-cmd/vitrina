"""Listings: creating, editing, publishing, photos, search, image search and the seller's shop tools."""
from __future__ import annotations

import io
from datetime import timedelta
from typing import Literal

from fastapi import BackgroundTasks, Depends, File, Request, UploadFile
from PIL import Image
from pydantic import BaseModel, Field
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import Authenticity, Condition, normalize_query
from vitrina_core.orders import OrderStatus as S

from . import services
from . import cutout, moderation, promo, visual
from .config import Settings
from .deps import current_user, get_db, get_settings, get_storage, now_utc, optional_user
from .errors import ApiError
from .social import size_fit
from .models import (PriceChange, StockAlert, ListingDailyViews, ListingEmbedding, ListingReport, Favorite, Listing,
                     ListingSize, Media, Order, User)
from .storage import MAX_UPLOAD_BYTES, Storage, normalize_image
from .api_common import ALMATY, DEFECT_REQUIRED, MAX_LISTING_MEDIA, MAX_LISTING_SIZES, MIN_SPIN_FRAMES, api, log
from .schemas import ListingIn, ListingPatch, PhotoIn, ReportIn
from .serializers import cm_to_mm, listing_out, mark_price_change, was_price
from .saved_search_routes import announce


def search_text(body: ListingIn) -> str:
    return normalize_query(" ".join(filter(None, [body.title, body.brand, body.model_name, body.color, body.category])))


@api.post("/media", status_code=201)
def upload_photo(file: UploadFile = File(...), user: User = Depends(current_user),
                       storage: Storage = Depends(get_storage)):
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    return {"url": storage.put(normalize_image(data), owner_id=user.id)}


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
                   cfg: Settings = Depends(get_settings), storage: Storage = Depends(get_storage)):
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    if not cfg.allow_external_media and not all(storage.owns(p.url, user.id) for p in body.photos):
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
    db.flush()
    db.add(PriceChange(listing_id=listing.id, price_tiyn=listing.price_tiyn))
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
                    cfg: Settings = Depends(get_settings), storage: Storage = Depends(get_storage)):
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


def route_after_checks(db: Session, storage: Storage, listing: Listing) -> None:
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
def edit_listing(listing_id: int, body: ListingPatch, request: Request, background: BackgroundTasks,
                 user: User = Depends(current_user), db: Session = Depends(get_db),
                 cfg: Settings = Depends(get_settings), storage: Storage = Depends(get_storage)):
    listing = own_listing(db, listing_id, user)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    changed = edit_contents(db, cfg, storage, listing, body, user)
    if body.price_tiyn is not None and body.price_tiyn != listing.price_tiyn:
        set_price(db, listing, body.price_tiyn)
        listing.pre_sale_price_tiyn = None  # the seller chose a price by hand: ending a sale must not undo it
        changed.add("price")
    if body.delivery_price_tiyn is not None:
        listing.delivery_price_tiyn = body.delivery_price_tiyn
    if body.description is not None and (body.description.strip() or None) != listing.description:
        listing.description = body.description.strip() or None
        changed.add("text")
    if body.defects is not None:
        if listing.condition in DEFECT_REQUIRED and not body.defects.strip():
            raise ApiError(422, "defects_required")
        if (body.defects.strip() or None) != listing.defects:
            listing.defects = body.defects.strip() or None
            changed.add("text")
    if listing.condition in DEFECT_REQUIRED and not (listing.defects or "").strip():
        raise ApiError(422, "defects_required")  # a worse condition always comes with what is wrong
    if (listing.announced_at is not None and listing.condition == Condition.DEFECTIVE.value
            and not any(m.angle == "defect" for m in listing.media)):
        raise ApiError(422, "defects_required", "a close-up photo of each defect is required")
    if body.sizes is not None:
        by_id = {s.id: s for s in listing.sizes}
        for item in body.sizes:
            if item.id not in by_id:
                raise ApiError(422, "validation", f"unknown size {item.id}")
            by_id[item.id].quantity = item.quantity
    if body.sizes is not None or body.add_sizes:
        settle_stock_status(listing)
    if changed and listing.announced_at is not None:
        recheck(db, storage, listing, changed)
        services.audit(db, user.id, "edit_listing", f"listing:{listing.id}", ",".join(sorted(changed)))
    services.tell_back_in_stock(db, listing)
    db.commit()
    if "photos" in changed:
        background.add_task(prepare_listing_media, request.app.state, listing.id)
    return listing_out(db, listing, owner=True)


def settle_stock_status(listing: Listing) -> None:
    """The one place stock decides status: a live listing with nothing left is sold; a sold one restocked waits,
    paused, for the seller to put it back on sale."""
    in_stock = any(s.quantity > 0 for s in listing.sizes)
    if listing.status == "published" and not in_stock:
        listing.status = "sold"
    elif listing.status == "sold" and in_stock:
        listing.status = "paused"


# What staff clearing a flag covered: once that kind of content changes, the clearance no longer applies.
CLEARANCE_OF = {"text": ("contacts", "replica"), "photos": ("reused_photo",), "price": ("low_price",),
                "name": ("contacts", "replica", "low_price")}


def recheck(db: Session, storage: Storage, listing: Listing, changed: set[str]) -> None:
    """Checks a change to a listing that has been on sale, whatever its status now (a sold or paused page is
    public too). A flagged change sends it to staff; a clean one never puts a listing on sale by itself."""
    stale = {code for part in changed for code in CLEARANCE_OF.get(part, ())}
    listing.moderation_cleared = ",".join(c for c in split_codes(listing.moderation_cleared) if c not in stale) or None
    flags = moderation.check(db, storage, listing)
    listing.moderation_flags = ",".join(flags) or None
    if set(flags) - set(split_codes(listing.moderation_cleared)):
        listing.status = "moderation"


CONDITION_ORDER = [c.value for c in Condition]  # best first


def edit_contents(db: Session, cfg: Settings, storage: Storage, listing: Listing, body: ListingPatch,
                  user: User) -> set[str]:
    """Name, photos and sizes. Returns which kinds of content buyers see actually changed."""
    fresh = listing.announced_at is None  # never on sale, whatever its status says now
    if not fresh and (body.category is not None and body.category != listing.category
                      or body.brand is not None and (body.brand.strip() or None) != listing.brand
                      or body.model_name is not None and (body.model_name.strip() or None) != listing.model_name):
        raise ApiError(409, "listing_locked")
    if (not fresh and body.condition is not None
            and CONDITION_ORDER.index(body.condition.value) < CONDITION_ORDER.index(listing.condition)):
        raise ApiError(409, "listing_locked")  # after sale a condition may only be marked worse, never better
    changed: set[str] = set()
    for field_name in ("title", "brand", "model_name", "color"):
        value = getattr(body, field_name)
        if value is None:
            continue
        value = value.strip() or None
        if field_name == "title" and (value is None or len(value) < 3) or field_name == "color" and (
                value is None or len(value) < 2):
            raise ApiError(422, "validation", f"{field_name} is too short")
        if value != getattr(listing, field_name):
            setattr(listing, field_name, value)
            changed.add("name")
    if body.category is not None and body.category != listing.category:
        listing.category = body.category
        changed.add("name")
    if body.condition is not None and body.condition.value != listing.condition:
        listing.condition = body.condition.value
        changed.add("text")
    if "name" in changed:
        listing.search_text = normalize_query(" ".join(filter(None, [listing.title, listing.brand, listing.model_name,
                                                                      listing.color, listing.category])))
    have = {m.original_url for m in listing.media}
    # A retry after a lost answer sends the same photos again: those already on the listing are skipped.
    added = [p for p in body.add_photos or [] if p.url not in have]
    new_photos = list(body.photos or []) + added
    if new_photos and not cfg.allow_external_media and not all(storage.owns(p.url, user.id) for p in new_photos):
        raise ApiError(422, "foreign_media")
    if body.photos is not None:
        frames = sum(p.angle == "frame" for p in body.photos)
        if 0 < frames < MIN_SPIN_FRAMES:
            raise ApiError(422, "too_few_frames")
        if [(m.original_url, m.angle) for m in listing.media] != [(p.url, p.angle) for p in body.photos]:
            # A listing that was on sale stays complete: orders keep their own copy of the photos they were placed on.
            if not fresh and sum(p.angle != "frame" for p in body.photos) < cfg.min_listing_photos:
                raise ApiError(422, "missing_required_photos")
            replace_photos(listing, body.photos)
            changed.add("photos")
    if added:
        added_frames = sum(p.angle == "frame" for p in added)
        if added_frames:
            # A rotation is one set shot in one go: frames are added only to a listing that has none yet.
            if any(m.angle == "frame" for m in listing.media):
                raise ApiError(409, "frames_exist")
            if added_frames < MIN_SPIN_FRAMES:
                raise ApiError(422, "too_few_frames")
        if len(listing.media) + len(added) > MAX_LISTING_MEDIA:
            raise ApiError(422, "too_many_photos")
        start = max((m.position for m in listing.media), default=-1) + 1
        listing.media.extend(Media(original_url=p.url, angle=p.angle, position=start + i) for i, p in enumerate(added))
        changed.add("photos")
    if body.add_sizes:
        known = {s.label.strip().lower() for s in listing.sizes}
        if len(listing.sizes) + len(body.add_sizes) > MAX_LISTING_SIZES:
            raise ApiError(422, "validation", "too many sizes")
        for size in body.add_sizes:
            if size.label.strip().lower() in known:
                raise ApiError(409, "size_exists")
            known.add(size.label.strip().lower())
            listing.sizes.append(ListingSize(label=size.label.strip(), insole_mm=cm_to_mm(size.insole_cm),
                                             quantity=size.quantity))
        db.flush()
    return changed


def replace_photos(listing: Listing, photos: list[PhotoIn]) -> None:
    """The new photo set, keeping the rows (cut-outs, hashes) of photos that stay; only new ones are processed."""
    kept = {(m.original_url, m.angle): m for m in listing.media}
    rows = []
    for i, p in enumerate(photos):
        row = kept.pop((p.url, p.angle), None) or Media(original_url=p.url, angle=p.angle)
        row.position = i
        rows.append(row)
    listing.media[:] = rows


class PromoIn(BaseModel):
    lang: Literal["kk", "ru", "en"] = "kk"


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
                            f"«{listing.title}» подешевел: {old_text} → {new_text}",
                            f"“{listing.title}” is cheaper: {old_text} → {new_text}", listing_id=listing.id)


class ShopSaleIn(BaseModel):
    percent: int = Field(ge=5, le=70)


def set_price(db: Session, listing: Listing, new: int) -> None:
    """One price change, the way the edit screen makes it: followers of a cut hear it, the old video goes."""
    if new == listing.price_tiyn:
        return
    if listing.promo_state == "ready":
        listing.promo_state, listing.promo_url = None, None  # the video shows the old price
    if new < listing.price_tiyn and listing.status == "published":
        notify_price_drop(db, listing, listing.price_tiyn, new)
    mark_price_change(db, listing, new)
    listing.price_tiyn = new


@api.post("/me/shop-sale")
def start_shop_sale(body: ShopSaleIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The same cut on every listing on sale, rounded to whole tenge. Each shows its old price crossed out."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    changed = 0
    for listing in db.scalars(select(Listing).where(Listing.seller_id == user.id, Listing.status == "published")):
        new = max(100, (listing.price_tiyn * (100 - body.percent) + 5000) // 10000 * 100)  # half up, as the app
        if new < listing.price_tiyn:
            if listing.pre_sale_price_tiyn is None:  # a second sale on top keeps the first original price
                listing.pre_sale_price_tiyn = listing.price_tiyn
            set_price(db, listing, new)
            changed += 1
    db.commit()
    return {"changed": changed}


@api.delete("/me/shop-sale")
def end_shop_sale(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Puts back the price each listing had before the sale; listings from before that was stored fall back to the
    crossed-out price."""
    changed = 0
    for listing in db.scalars(select(Listing).where(Listing.seller_id == user.id)):
        old = listing.pre_sale_price_tiyn or was_price(listing)
        listing.pre_sale_price_tiyn = None
        if old is not None and old != listing.price_tiyn:
            set_price(db, listing, old)
            changed += 1
    db.commit()
    return {"changed": changed}


@api.post("/listings/{listing_id}/pause")
def pause_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status != "published":
        raise ApiError(409, "invalid_status")
    listing.status = "paused"
    db.commit()
    return listing_out(db, listing, owner=True)


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
    return {**listing_out(db, listing, owner=owner), "size_fit": size_fit(db, listing), "stock_alerts": alerts,
            "popularity": popularity(db, listing)}


POPULAR_DAYS = 30
POPULAR_MIN_FAVORITES = 3  # one or two hearts say little; below this nothing is shown


def popularity(db: Session, listing: Listing) -> dict | None:
    """Real demand a buyer may weigh: pairs bought in the last 30 days (orders that stand, not cancelled or
    refunded) and how many people saved it. None when there is nothing worth saying."""
    since = now_utc() - timedelta(days=POPULAR_DAYS)
    sold = int(db.scalar(select(func.count(Order.id)).where(
        Order.listing_id == listing.id, Order.created_at >= since,
        Order.status.not_in([S.CREATED.value, S.PAYMENT_PENDING.value, S.CANCELLED.value,
                             S.REFUND_PENDING.value, S.REFUNDED.value]))) or 0)
    saved = int(db.scalar(select(func.count(Favorite.id)).where(Favorite.listing_id == listing.id)) or 0)
    if not sold and saved < POPULAR_MIN_FAVORITES:
        return None
    return {"sold_30d": sold, "favorites": saved if saved >= POPULAR_MIN_FAVORITES else 0}


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
