"""How models are shown to clients: listings, orders and profiles as JSON."""
from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation

from sqlalchemy import func, select
from sqlalchemy.orm import Session, lazyload, raiseload

from vitrina_core.catalog import compute_bounds
from vitrina_core.orders import OrderStatus as S

from . import services
from . import moderation
from .deps import now_utc
from .errors import ApiError
from .social import seller_rating
from .models import PriceChange, Favorite, Listing, ListingSize, Media, Order, Question, Review, User, question_waiting
from .api_common import ALMATY
from .storage import private_link


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


def per_request(db: Session, name: str, key, make):
    """A value computed once per request (the session lives exactly one request): a page of 20 listings from the
    same category or seller asks the same question 20 times."""
    memo = db.info.setdefault(name, {})
    if key not in memo:
        memo[key] = make()
    return memo[key]


_BOUNDS: dict[tuple, tuple] = {}


def segment_bounds(db: Session, category: str):
    """The category's price bands. Rebuilt only when its prices change, which one aggregate tells, instead of
    reading and sorting every price in the category for each page (the whole catalog when it is all sneakers)."""
    on_sale = (Listing.category == category, Listing.status.in_(("published", "sold")))
    version = tuple(db.execute(select(func.count(Listing.id), func.max(Listing.id), func.sum(Listing.price_tiyn))
                               .where(*on_sale)).one())
    key = (id(db.get_bind()), category)
    cached = _BOUNDS.get(key)
    if cached and cached[0] == version:
        return cached[1]
    bounds = compute_bounds(category, list(db.scalars(select(Listing.price_tiyn).where(*on_sale))))
    _BOUNDS[key] = (version, bounds)
    return bounds


def segment_for(db: Session, listing: Listing) -> str | None:
    b = per_request(db, "segment_bounds", listing.category, lambda: segment_bounds(db, listing.category))
    return b.segment_for(listing.price_tiyn).value if b else None


def listing_stats(db: Session, listing: Listing) -> dict:
    """How the listing is doing, for its seller only."""
    from .models import Conversation
    batch = db.info.get("listing_stats")
    if batch is not None and listing.id in batch:
        return {"views": listing.views, **batch[listing.id]}
    count = lambda stmt: int(db.scalar(stmt) or 0)  # noqa: E731
    return {
        "views": listing.views,
        "favorites": count(select(func.count(Favorite.id)).where(Favorite.listing_id == listing.id)),
        "chats": count(select(func.count(Conversation.id)).where(Conversation.listing_id == listing.id)),
        "orders": count(select(func.count(Order.id)).where(Order.listing_id == listing.id,
                                                          Order.status != S.CANCELLED.value)),
        "sold": count(select(func.count(Order.id)).where(Order.listing_id == listing.id,
                                                        Order.status == S.COMPLETED.value)),
        # Buyers' questions still waiting for the seller, the same count as the to-do card's, per listing.
        "unanswered": count(select(func.count(Question.id)).join(Listing, Listing.id == Question.listing_id)
                            .where(Question.listing_id == listing.id, *question_waiting())),
    }


# For a query of a page of listings: their photos are read by with_light_media, never one by one through the ORM.
LIGHT = raiseload(Listing.media)
# A listing read only for its title and cover: no photos or sizes through the ORM (~43 rows a listing), and lazy
# rather than raising should anything else still ask for them.
BARE = (lazyload(Listing.media), lazyload(Listing.sizes))


def with_light_media(db: Session, listings: list[Listing]) -> list[Listing]:
    """Reads the photos of a page of listings in one query as plain rows. A card carries every 360° frame, ~43 rows
    a listing, and making each an ORM object took a third of a catalog page. Load the page with options(LIGHT)."""
    by_listing = defaultdict(list)
    ids = [listing.id for listing in listings]
    if ids:
        for m in db.execute(select(Media.listing_id, Media.original_url, Media.processed_url, Media.thumb_url,
                                   Media.angle, Media.position, Media.no_cutout)
                            .where(Media.listing_id.in_(ids)).order_by(Media.listing_id, Media.position, Media.id)):
            by_listing[m.listing_id].append(m)
    for listing in listings:
        listing._light_media = by_listing[listing.id]
    return listings


def with_covers(db: Session, listings: list[Listing]) -> list[Listing]:
    """Only the cover of each listing, for rows that show nothing else: the photos without the 360° frames (a few a
    listing, not ~43), in one query for the page; listing_cover then takes the first."""
    ids = [listing.id for listing in listings if "_cover" not in listing.__dict__]
    covers: dict[int, str | None] = {}
    if ids:
        for lid, original, processed in db.execute(
                select(Media.listing_id, Media.original_url, Media.processed_url)
                .where(Media.listing_id.in_(ids), Media.angle != "frame")
                .order_by(Media.listing_id, Media.position, Media.id)):
            covers.setdefault(lid, processed or original)
        for listing in listings:
            if listing.id in ids:
                listing._cover = covers.get(listing.id)
    return listings


def media_of(listing: Listing) -> list:
    """The listing's photos in order: as read by with_light_media for a page, else through the ORM."""
    light = listing.__dict__.get("_light_media")
    return listing.media if light is None else light


def listing_out(db: Session, listing: Listing, *, owner: bool = False) -> dict:
    """owner=True adds stock counts and statistics, which only the seller sees."""
    # Held for the request: the session keeps only objects someone holds, so a page of one shop's listings would
    # otherwise read the seller again for every one.
    seller = per_request(db, "seller", listing.seller_id, lambda: db.get(User, listing.seller_id))
    return {
        "id": listing.id, "status": listing.status, "title": listing.title, "category": listing.category, "audience": listing.audience,
        "brand": listing.brand, "model_name": listing.model_name, "color": listing.color,
        "price_tiyn": listing.price_tiyn, "was_price_tiyn": was_price(listing),
        "delivery_price_tiyn": listing.delivery_price_tiyn,
        # Three separate facts, never merged into one "quality" label.
        "segment": segment_for(db, listing), "condition": listing.condition, "authenticity": listing.authenticity,
        "defects": listing.defects, "description": listing.description, "showcase_style": listing.showcase_style,
        "backdrop": listing.backdrop, "cover_frame": cover_frame(listing),
        "angle_frames": angle_frames(listing),
        "sizes": [{"id": s.id, "label": s.label, "insole_cm": mm_to_cm(s.insole_mm), "available": s.quantity > 0,
                   **({"quantity": s.quantity} if owner else {})} for s in listing.sizes],
        "media": [{"original_url": m.original_url, "processed_url": m.processed_url, "thumb_url": m.thumb_url,
                   "angle": m.angle,
                   # The seller is told so that they can take it again; a buyer only sees the photo as taken.
                   **({"no_shoe": m.no_cutout is not None} if owner else {})}
                  for m in media_of(listing)],
        "photos_version": photos_version(listing),
        "seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,  # never the phone
                   "away_until": away_out(seller),
                   **per_request(db, "seller_rating", seller.id, lambda: seller_rating(db, seller.id))},
        **({"stats": listing_stats(db, listing), "ever_on_sale": listing.announced_at is not None,
            "promo": {"state": listing.promo_state, "url": listing.promo_url},
            "moderation": moderation_out(listing), "photos_pending": photos_pending(listing)} if owner else {}),
    }


SALE_DAYS = 14  # how long a cut price is shown against the old one


PRICE_LOOKBACK = timedelta(days=30)


def lowest_recent_price(db: Session, listing: Listing, now: datetime) -> int:
    """The lowest price the listing had at any moment of the last 30 days, the current one included."""
    since = now - PRICE_LOOKBACK
    before = db.scalar(select(PriceChange.price_tiyn).where(PriceChange.listing_id == listing.id,
                                                            PriceChange.at <= since)
                       .order_by(PriceChange.at.desc(), PriceChange.id.desc()).limit(1))
    during = db.scalars(select(PriceChange.price_tiyn).where(PriceChange.listing_id == listing.id,
                                                             PriceChange.at > since)).all()
    return min([listing.price_tiyn, *during, *([before] if before is not None else [])])


def mark_price_change(db: Session, listing: Listing, new_price: int) -> None:
    """The crossed-out price is the lowest price of the last 30 days, so a price raised only to be cut shows no
    sale. Further cuts during a sale keep its first reference. A cut of under 5% is not a sale."""
    now = now_utc()
    live = listing.was_price_tiyn if listing.was_until and services.aware(listing.was_until) > now else None
    reference = live or lowest_recent_price(db, listing, now)
    if new_price <= reference * 0.95:
        listing.was_price_tiyn, listing.was_until = reference, now + timedelta(days=SALE_DAYS)
    elif new_price >= reference or live is None:
        listing.was_price_tiyn, listing.was_until = None, None
    db.add(PriceChange(listing_id=listing.id, price_tiyn=new_price, at=now))


def was_price(listing: Listing) -> int | None:
    if listing.was_price_tiyn and listing.was_until and services.aware(listing.was_until) > now_utc() \
            and listing.was_price_tiyn > listing.price_tiyn:
        return listing.was_price_tiyn
    return None


def moderation_out(listing: Listing) -> dict:
    flags = [c for c in (listing.moderation_flags or "").split(",") if c]
    return {"flags": flags, "reasons": [moderation.REASONS[c][0] for c in flags if c in moderation.REASONS],
            "reasons_ru": [moderation.REASONS[c][1] for c in flags if c in moderation.REASONS],
            "reasons_en": [moderation.REASONS[c][2] for c in flags if c in moderation.REASONS],
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


def cover_photo(listing: Listing):
    """The photo shown on cards: the first that is not a 360° frame."""
    return next((m for m in media_of(listing) if m.angle != "frame"), None)


def cover_frame(listing: Listing) -> str | None:
    """The frame matching the cover, while both are still the listing's."""
    cover = cover_photo(listing)
    if (cover is None or listing.cover_frame is None or listing.cover_frame_of != cover.original_url
            or not any(m.angle == "frame" and m.original_url == listing.cover_frame for m in media_of(listing))):
        return None
    return listing.cover_frame


def showcase_parts(media: list) -> list[list]:
    """The frames as the app splits them into showcase steps (ShowcasePlan.of), in the order taken: a scan's
    turn, then each stop's own frames; otherwise all of them, one turn. Each part shows its cut-outs only when
    every frame of it has one. A scan carries on over the top and under the sole after its turn, its stop photos
    being frames at increasing places."""
    frames = [m for m in media if m.angle == "frame"]
    at = [next((i for i, f in enumerate(frames) if f.original_url == m.original_url), -1)
          for m in (next((m for m in media if m.angle == angle), None) for angle in ("top", "sole", "detail")) if m]
    if frames and at and at[0] > 0 and all(b > a for a, b in zip(at, at[1:])):
        return [frames[a:b] for a, b in zip([0, *at], [*at, len(frames)])]
    return [frames] if frames else []


def one_turn(media: list) -> tuple[list, bool]:
    """The frames of one 360° turn as the app shows it, in the order taken, and whether they are a scan (see
    showcase_parts). One turn ends where its first frame comes round again."""
    parts = showcase_parts(media)
    frames, scan = (parts[0] if parts else []), len(parts) > 1
    return next((frames[:k] for k in range(1, len(frames)) if frames[k].original_url == frames[0].original_url),
                frames), scan


def side_photo(listing: Listing, angle: str):
    """The listing's photo of one side (outer, front, inner or back), as the cover and the app pick it: the first."""
    return next((m for m in media_of(listing) if m.angle == angle), None)


def angle_frames(listing: Listing) -> dict[str, str]:
    """For each side photographed, the 360° frame showing that side, while the photo and the frame are still the
    listing's: where the toe or a side faces the camera, so shoes turned either way or unevenly line up."""
    try:
        stored = json.loads(listing.angle_frames or "{}")
    except ValueError:
        return {}
    frames = {m.original_url for m in media_of(listing) if m.angle == "frame"}
    out = {}
    for angle, mark in stored.items() if isinstance(stored, dict) else ():
        photo = side_photo(listing, angle)
        if (isinstance(mark, dict) and photo is not None and mark.get("of") == photo.original_url
                and mark.get("frame") in frames):
            out[angle] = mark["frame"]
    return out


def listing_cover(listing: Listing) -> str | None:
    if "_cover" in listing.__dict__:  # read by with_covers
        return listing.__dict__["_cover"]
    return next((m.processed_url or m.original_url for m in media_of(listing) if m.angle != "frame"), None)


# Photo work takes a few minutes a listing; past this something went wrong, which the worker's log says, and the
# seller is no longer told to wait.
PHOTOS_PENDING_FOR = timedelta(days=1)


def photos_pending(listing: Listing) -> bool:
    """For the seller: the photos they just gave are still being prepared (cut out, small copies for scrolling, the
    360° start), so buyers see them as taken for now. The small copies are made last, after the cut-outs."""
    changed = services.aware(listing.photos_changed_at)
    return (changed is not None and now_utc() - changed < PHOTOS_PENDING_FOR
            and any(m.thumb_url is None for m in media_of(listing)))


def photos_version(listing: Listing) -> str:
    """Names the photo set and the text (condition, defects, description) a buyer is looking at. An order placed
    from an older version is refused, so the copy kept with the order is what the buyer actually saw, not an edit
    made while they were deciding."""
    shown = sorted(media_of(listing), key=lambda m: m.position)
    lines = [f"{m.original_url} {m.angle}" for m in shown] + [details_snapshot(listing)]
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16]


def photo_snapshot(listing: Listing) -> str:
    return json.dumps([{"url": m.processed_url or m.original_url, "original_url": m.original_url, "angle": m.angle}
                       for m in sorted(media_of(listing), key=lambda m: m.position)], ensure_ascii=False)


LISTING_DETAILS = ("title", "brand", "model_name", "color", "category", "condition", "defects", "description",
                   "authenticity")


def details_snapshot(listing: Listing) -> str:
    return json.dumps({f: getattr(listing, f) for f in LISTING_DETAILS}, ensure_ascii=False)


def ordered_details(order: Order) -> dict | None:
    """What the listing said when ordered: its condition and defects as the buyer read them. backfilled=True marks
    orders placed before these copies were kept, filled from the listing as it read on the day of the upgrade."""
    return json.loads(order.listing_details) if order.listing_details else None


def evidence_out(order: Order, item, files) -> dict:
    return {"id": item.id, "from": "buyer" if item.user_id == order.buyer_id else "seller",
            "url": private_link(files, item.url), "kind": item.kind, "note": item.note,
            "at": services.aware(item.created_at).isoformat()}


def ordered_photos(order: Order) -> list[dict] | None:
    """The photos the buyer saw when ordering; None for orders placed before snapshots were kept."""
    return json.loads(order.listing_photos) if order.listing_photos else None


def preload(db: Session, name: str, model, ids, *options) -> dict:
    """Rows a page names by id, read in one query into the per_request memo `name` (only those not there yet)."""
    memo = db.info.setdefault(name, {})
    missing = set(ids) - memo.keys()
    if missing:
        for row in db.scalars(select(model).options(*options).where(model.id.in_(missing))):
            memo[row.id] = row
    return memo


def preload_bare_listings(db: Session, ids, covers: bool = True) -> dict:
    """Listings a row shows only by title and cover: no ORM photos or sizes, and only the cover read (with_covers)."""
    memo = preload(db, "bare_listing", Listing, ids, *BARE)
    if covers:
        with_covers(db, [memo[i] for i in set(ids) if i in memo])
    return memo


def preload_sellers(db: Session, ids) -> dict:
    """Sellers a page shows, with their rating, in two queries for the page: listing_out then finds both."""
    sellers = preload(db, "seller", User, ids)
    ratings = db.info.setdefault("seller_rating", {})
    missing = set(ids) - ratings.keys()
    if missing:
        ratings.update({i: {"rating": None, "reviews": 0} for i in missing})
        for seller_id, avg, count in db.execute(select(Review.seller_id, func.avg(Review.rating), func.count(Review.id))
                                                .where(Review.seller_id.in_(missing)).group_by(Review.seller_id)):
            ratings[seller_id] = {"rating": round(float(avg), 1) if avg is not None else None, "reviews": int(count)}
    return sellers


def bare_listing(db: Session, listing_id: int) -> Listing:
    return per_request(db, "bare_listing", listing_id, lambda: db.get(Listing, listing_id))


def size_row(db: Session, size_id: int) -> ListingSize | None:
    return per_request(db, "size", size_id, lambda: db.get(ListingSize, size_id))


def preload_orders(db: Session, orders: list[Order]) -> None:
    """Reads what a list of orders shows (listings, sizes, sellers) in a few queries for the whole list; order_summary
    then finds them here instead of reading three rows an order."""
    if not orders:
        return
    preload(db, "size", ListingSize, {o.size_id for o in orders})
    preload(db, "seller", User, {o.seller_id for o in orders})
    # Orders from before the cover was kept on the order take it from the listing's photos, all in one query.
    preload_bare_listings(db, {o.listing_id for o in orders}, covers=False)
    preload_bare_listings(db, {o.listing_id for o in orders if not o.listing_cover})


def order_summary(db: Session, order: Order) -> dict:
    """Order plus what a list row needs to be recognisable: the item's title, size and photo."""
    listing, size = bare_listing(db, order.listing_id), size_row(db, order.size_id)
    seller = per_request(db, "seller", order.seller_id, lambda: db.get(User, order.seller_id))
    cover = order.listing_cover or listing_cover(listing)
    return {**order_out(order), "listing_title": order.listing_title or listing.title, "listing_cover": cover,
            "size_label": size.label, "size_cm": mm_to_cm(size.insole_mm),
            "seller_name": seller.shop_name, "created_at": services.aware(order.created_at).isoformat()}


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
            "away_until": away_out(user), "last_delivery": json.loads(user.last_delivery) if user.last_delivery else None,
            "shop_about": user.shop_about}
