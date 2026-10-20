"""Price offers: a buyer names a price, the seller accepts, declines or answers with their own.

An accepted offer is a promise for that buyer only: they can order that size at that price for a day, through the
same protected payment as any order. Offers never change the listing's public price.
"""
from __future__ import annotations

import math
from datetime import timedelta, timezone

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import promo, services
from .config import Settings
from .deps import current_user, get_db, get_settings, now_utc
from .errors import ApiError
from .models import Listing, ListingSize, Offer, User
from .serializers import bare_listing, listing_cover, preload, preload_bare_listings, size_row

router = APIRouter(prefix="/api/v1")

MIN_RATIO = 0.5                      # offers under half the price are not sent to the seller
ANSWER_WITHIN = timedelta(hours=48)  # a pending or countered offer lapses after this
BUY_WITHIN = timedelta(hours=24)     # an accepted offer can be ordered for this long
OFFERS_PER_DAY = 3                   # per buyer per listing, so a seller is not haggled to death
OPEN = ("pending", "countered", "accepted")
ALMATY = timezone(timedelta(hours=5))


class OfferIn(BaseModel):
    size_id: int
    amount_tiyn: int = Field(gt=0)


class CounterIn(BaseModel):
    amount_tiyn: int = Field(gt=0)


def state(offer: Offer) -> str:
    if offer.status in OPEN and services.aware(offer.expires_at) <= now_utc():
        return "expired"
    return offer.status


def price(offer: Offer) -> int:
    """What the buyer pays for the item once the offer is accepted."""
    return offer.counter_tiyn if offer.counter_tiyn is not None else offer.amount_tiyn


def waiting_count(db: Session, mine: list, status: str) -> int:
    """How many of these offers wait for an answer: in that status and not lapsed (as state() sees them)."""
    return int(db.scalar(select(func.count(Offer.id)).where(*mine, Offer.status == status,
                                                          Offer.expires_at > now_utc())) or 0)


def offer_out(db: Session, offer: Offer) -> dict:
    listing, size = bare_listing(db, offer.listing_id), size_row(db, offer.size_id)
    # The same cover as an order or chat of this listing shows (the cut-out once there is one).
    return {"id": offer.id, "listing_id": listing.id, "listing_title": listing.title,
            "listing_cover": listing_cover(listing),
            "list_price_tiyn": listing.price_tiyn, "size_id": size.id, "size_label": size.label,
            "amount_tiyn": offer.amount_tiyn, "counter_tiyn": offer.counter_tiyn, "price_tiyn": price(offer),
            "status": state(offer), "buyer_id": offer.buyer_id, "seller_id": offer.seller_id,
            "expires_at": services.aware(offer.expires_at).isoformat(), "order_id": offer.order_id}


def whole_tenge(amount_tiyn: int) -> None:
    if amount_tiyn % 100:
        raise ApiError(422, "validation", "amount must be whole tenge")


def payments_on(cfg: Settings = Depends(get_settings)) -> None:
    """An agreed price could not be paid while online payment is off: no offers are made, accepted or countered then.
    Declining and withdrawing stay open, so offers left from before can be closed."""
    if cfg.payments == "off":
        raise ApiError(503, "payments_off")


@router.post("/listings/{listing_id}/offers", status_code=201)
def make_offer(listing_id: int, body: OfferIn, user: User = Depends(current_user), db: Session = Depends(get_db),
               _: None = Depends(payments_on)):
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    seller = db.get(User, listing.seller_id)
    if seller.away_until and seller.away_until >= now_utc().astimezone(ALMATY).date():
        raise ApiError(409, "seller_away")
    size = db.get(ListingSize, body.size_id)
    if size is None or size.listing_id != listing.id or size.quantity <= 0:
        raise ApiError(409, "out_of_stock")
    whole_tenge(body.amount_tiyn)
    if body.amount_tiyn >= listing.price_tiyn:
        raise ApiError(422, "offer_not_lower")
    if body.amount_tiyn < math.ceil(listing.price_tiyn * MIN_RATIO):
        raise ApiError(422, "offer_too_low")
    now = now_utc()
    recent = db.scalar(select(func.count(Offer.id)).where(Offer.listing_id == listing.id, Offer.buyer_id == user.id,
                                                          Offer.created_at >= now - timedelta(days=1)))
    if (recent or 0) >= OFFERS_PER_DAY:
        raise ApiError(429, "offer_limit")
    for old in db.scalars(select(Offer).where(Offer.listing_id == listing.id, Offer.buyer_id == user.id,
                                              Offer.status.in_(OPEN))
                              .with_for_update().execution_options(populate_existing=True)).all():
        old.status = "withdrawn"  # one live offer per buyer per listing: the newest one counts
    offer = Offer(listing_id=listing.id, size_id=size.id, buyer_id=user.id, seller_id=listing.seller_id,
                  amount_tiyn=body.amount_tiyn, status="pending", created_at=now, expires_at=now + ANSWER_WITHIN)
    db.add(offer)
    db.flush()
    amount = promo.format_tenge(body.amount_tiyn)
    services.notify(db, listing.seller_id, "offer", f"«{listing.title}», {size.label}: {amount} ұсынды.",
                    f"«{listing.title}», {size.label}: предложили {amount}.",
                    f"“{listing.title}”, {size.label}: offered {amount}.", listing_id=listing.id)
    db.commit()
    return offer_out(db, offer)


@router.get("/offers")
def list_offers(role: str = "buyer", listing_id: int | None = None,
                before: int | None = Query(default=None, ge=1, le=2**31 - 1),
                limit: int = Query(default=100, ge=1, le=100), user: User = Depends(current_user),
                db: Session = Depends(get_db)):
    """Newest first, a page at a time by id (next_before: the cursor for the next page, null after the last). waiting
    counts every offer that waits for this user's answer, not only those on this page; it comes with the first page
    only (null on the others, the same for the whole list)."""
    column = Offer.seller_id if role == "seller" else Offer.buyer_id
    mine = [column == user.id] + ([Offer.listing_id == listing_id] if listing_id is not None else [])
    q = select(Offer).where(*mine)
    if before is not None:
        q = q.where(Offer.id < before)
    rows = db.scalars(q.order_by(Offer.id.desc()).limit(limit + 1)).all()
    rows, more = rows[:limit], len(rows) > limit
    preload_bare_listings(db, {o.listing_id for o in rows})
    preload(db, "size", ListingSize, {o.size_id for o in rows})
    items = [offer_out(db, o) for o in rows]
    waiting = waiting_count(db, mine, "pending" if role == "seller" else "countered") if before is None else None
    return {"items": items, "waiting": waiting,
            "next_before": rows[-1].id if more else None}


def own_offer(db: Session, offer_id: int, user: User) -> Offer:
    """The offer, locked and read afresh for an answer: two answers at once (accept and decline, a double tap) are
    taken one after the other, and the second sees the first."""
    offer = locked(db, offer_id)
    if offer is None or user.id not in (offer.buyer_id, offer.seller_id):
        raise ApiError(404, "not_found")
    return offer


def locked(db: Session, offer_id: int) -> Offer | None:
    return db.scalar(select(Offer).where(Offer.id == offer_id).with_for_update()
                     .execution_options(populate_existing=True))


def answer(offer: Offer, user: User) -> None:
    """Only the side whose turn it is may answer: the seller a fresh offer, the buyer the seller's price."""
    turn = {"pending": offer.seller_id, "countered": offer.buyer_id}.get(state(offer))
    if turn != user.id:
        raise ApiError(409, "invalid_status")


def tell_other(db: Session, offer: Offer, user: User, kk: str, ru: str, en: str) -> None:
    listing = db.get(Listing, offer.listing_id)
    other = offer.buyer_id if user.id == offer.seller_id else offer.seller_id
    kind = "offer" if other == offer.seller_id else "offer_reply"  # the app opens the seller's inbox for "offer"
    services.notify(db, other, kind, f"«{listing.title}»: {kk}", f"«{listing.title}»: {ru}", f"“{listing.title}”: {en}",
                    listing_id=listing.id)


@router.post("/offers/{offer_id}/accept")
def accept_offer(offer_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
                 _: None = Depends(payments_on)):
    offer = own_offer(db, offer_id, user)
    answer(offer, user)
    offer.status, offer.expires_at = "accepted", now_utc() + BUY_WITHIN
    amount = promo.format_tenge(price(offer))
    if user.id == offer.seller_id:
        tell_other(db, offer, user, f"сатушы {amount} бағаны қабылдады. Тәулік ішінде рәсімдеңіз.",
                   f"продавец принял цену {amount}. Оформите заказ в течение суток.",
                   f"the seller accepted {amount}. Place the order within 24 hours.")
    else:
        tell_other(db, offer, user, f"сатып алушы {amount} бағаңызға келісті.",
                   f"покупатель согласился на вашу цену {amount}.", f"the buyer agreed to your price of {amount}.")
    db.commit()
    return offer_out(db, offer)


@router.post("/offers/{offer_id}/decline")
def decline_offer(offer_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    offer = own_offer(db, offer_id, user)
    answer(offer, user)
    offer.status = "declined"
    tell_other(db, offer, user, "ұсыныс қабылданбады.", "предложение отклонено.", "the offer was declined.")
    db.commit()
    return offer_out(db, offer)


@router.post("/offers/{offer_id}/counter")
def counter_offer(offer_id: int, body: CounterIn, user: User = Depends(current_user), db: Session = Depends(get_db),
                  _: None = Depends(payments_on)):
    offer = own_offer(db, offer_id, user)
    if user.id != offer.seller_id:
        raise ApiError(409, "invalid_status")
    answer(offer, user)
    listing = db.get(Listing, offer.listing_id)
    whole_tenge(body.amount_tiyn)
    if not offer.amount_tiyn < body.amount_tiyn < listing.price_tiyn:
        raise ApiError(422, "counter_out_of_range")
    offer.status, offer.counter_tiyn, offer.expires_at = "countered", body.amount_tiyn, now_utc() + ANSWER_WITHIN
    amount = promo.format_tenge(body.amount_tiyn)
    tell_other(db, offer, user, f"сатушы {amount} баға ұсынды.", f"продавец предлагает {amount}.",
               f"the seller offers {amount}.")
    db.commit()
    return offer_out(db, offer)


@router.post("/offers/{offer_id}/withdraw")
def withdraw_offer(offer_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    offer = own_offer(db, offer_id, user)
    if user.id != offer.buyer_id or state(offer) not in OPEN:
        raise ApiError(409, "invalid_status")
    offer.status = "withdrawn"
    db.commit()
    return offer_out(db, offer)


def offer_for_order(db: Session, offer_id: int, user: User, listing: Listing, size_id: int) -> Offer:
    """The accepted offer an order is placed under; anything else about it is a client error. Locked, so two orders
    at once cannot both use it."""
    offer = locked(db, offer_id)
    if (offer is None or offer.buyer_id != user.id or offer.listing_id != listing.id
            or offer.size_id != size_id):
        raise ApiError(404, "not_found")
    if state(offer) != "accepted":
        raise ApiError(409, "offer_not_active")
    return offer
