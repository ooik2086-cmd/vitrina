"""How models are shown to clients: listings, orders and profiles as JSON."""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.catalog import compute_bounds
from vitrina_core.orders import OrderStatus as S

from . import services
from . import moderation
from .deps import now_utc
from .errors import ApiError
from .social import seller_rating
from .models import PriceChange, Favorite, Listing, ListingSize, Order, User
from .api_common import ALMATY


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


def segment_for(db: Session, listing: Listing) -> str | None:
    def bounds():
        prices = db.scalars(select(Listing.price_tiyn).where(Listing.category == listing.category,
                                                             Listing.status.in_(("published", "sold")))).all()
        return compute_bounds(listing.category, list(prices))
    b = per_request(db, "segment_bounds", listing.category, bounds)
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
        "photos_version": photos_version(listing),
        "seller": {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,  # never the phone
                   "away_until": away_out(seller),
                   **per_request(db, "seller_rating", seller.id, lambda: seller_rating(db, seller.id))},
        **({"stats": listing_stats(db, listing), "ever_on_sale": listing.announced_at is not None,
            "promo": {"state": listing.promo_state, "url": listing.promo_url},
            "moderation": moderation_out(listing)} if owner else {}),
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


def listing_cover(listing: Listing) -> str | None:
    return next((m.processed_url or m.original_url for m in listing.media if m.angle != "frame"), None)


def photos_version(listing: Listing) -> str:
    """Names the photo set and the text (condition, defects, description) a buyer is looking at. An order placed
    from an older version is refused, so the copy kept with the order is what the buyer actually saw, not an edit
    made while they were deciding."""
    shown = sorted(listing.media, key=lambda m: m.position)
    lines = [f"{m.original_url} {m.angle}" for m in shown] + [details_snapshot(listing)]
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16]


def photo_snapshot(listing: Listing) -> str:
    return json.dumps([{"url": m.processed_url or m.original_url, "original_url": m.original_url, "angle": m.angle}
                       for m in sorted(listing.media, key=lambda m: m.position)], ensure_ascii=False)


LISTING_DETAILS = ("title", "brand", "model_name", "color", "category", "condition", "defects", "description",
                   "authenticity")


def details_snapshot(listing: Listing) -> str:
    return json.dumps({f: getattr(listing, f) for f in LISTING_DETAILS}, ensure_ascii=False)


def ordered_details(order: Order) -> dict | None:
    """What the listing said when ordered: its condition and defects as the buyer read them. backfilled=True marks
    orders placed before these copies were kept, filled from the listing as it read on the day of the upgrade."""
    return json.loads(order.listing_details) if order.listing_details else None


def evidence_out(order: Order, item) -> dict:
    return {"id": item.id, "from": "buyer" if item.user_id == order.buyer_id else "seller", "url": item.url, "kind": item.kind, "note": item.note,
            "at": services.aware(item.created_at).isoformat()}


def ordered_photos(order: Order) -> list[dict] | None:
    """The photos the buyer saw when ordering; None for orders placed before snapshots were kept."""
    return json.loads(order.listing_photos) if order.listing_photos else None


def order_summary(db: Session, order: Order) -> dict:
    """Order plus what a list row needs to be recognisable: the item's title, size and photo."""
    listing = db.get(Listing, order.listing_id)
    size = db.get(ListingSize, order.size_id)
    cover = order.listing_cover or listing_cover(listing)
    return {**order_out(order), "listing_title": order.listing_title or listing.title, "listing_cover": cover,
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
            "away_until": away_out(user), "last_delivery": json.loads(user.last_delivery) if user.last_delivery else None,
            "shop_about": user.shop_about}
