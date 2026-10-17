"""Seller promo codes: a percent or a fixed sum off one pair.

The discount comes off the order's item price, so the seller pays for it and commission is taken from what the
buyer actually pays. A code works once per buyer and is counted only while its order stands: a cancelled or
refunded order gives the use back.
"""
from __future__ import annotations

import re
from datetime import date, timedelta, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus as S

from . import services
from .deps import current_user, get_db, now_utc
from .errors import ApiError
from .models import Listing, Order, PromoCode, User

router = APIRouter(prefix="/api/v1")

ALMATY = timezone(timedelta(hours=5))
CODE = re.compile(r"^[A-Z0-9]{4,20}$")
MAX_PERCENT = 50
# Orders that no longer hold a use of the code.
RELEASED = (S.CANCELLED.value, S.REFUND_PENDING.value, S.REFUNDED.value)


def clean_code(raw: str) -> str:
    return raw.strip().upper()


class PromoIn(BaseModel):
    code: str = Field(min_length=4, max_length=20)
    percent: int | None = Field(default=None, ge=5, le=MAX_PERCENT)
    amount_tiyn: int | None = Field(default=None, ge=10_000)  # at least 100 ₸
    min_price_tiyn: int = Field(default=0, ge=0)
    max_uses: int | None = Field(default=None, ge=1, le=100_000)
    ends_on: date | None = None

    @model_validator(mode="after")
    def one_kind(self):
        if (self.percent is None) == (self.amount_tiyn is None):
            raise ValueError("give either percent or amount_tiyn")
        if not CODE.match(clean_code(self.code)):
            raise ValueError("code is 4-20 Latin letters or digits")
        for v in (self.amount_tiyn, self.min_price_tiyn):
            if v and v % 100:
                raise ValueError("amounts must be whole tenge")
        return self


def uses(db: Session, promo: PromoCode, buyer_id: int | None = None) -> int:
    q = select(func.count(Order.id)).where(Order.promo_code_id == promo.id, Order.status.not_in(RELEASED))
    if buyer_id is not None:
        q = q.where(Order.buyer_id == buyer_id)
    return db.scalar(q)


def today() -> date:
    return now_utc().astimezone(ALMATY).date()


def promo_out(db: Session, promo: PromoCode) -> dict:
    expired = promo.ends_on is not None and promo.ends_on < today()
    return {"id": promo.id, "code": promo.code, "percent": promo.percent, "amount_tiyn": promo.amount_tiyn,
            "min_price_tiyn": promo.min_price_tiyn, "max_uses": promo.max_uses,
            "ends_on": promo.ends_on.isoformat() if promo.ends_on else None, "uses": uses(db, promo),
            "active": promo.active and not expired}


def discount(promo: PromoCode, price_tiyn: int) -> int:
    """Whole tenge off; never more than half the price, so a typo in a code cannot give a pair away."""
    off = price_tiyn * promo.percent // 100 if promo.percent else promo.amount_tiyn
    return min(off, price_tiyn // 2) // 100 * 100


def apply(db: Session, raw_code: str, listing: Listing, price_tiyn: int, buyer: User, lock: bool = False):
    """The code's row and its discount on this price, or the reason it does not work here."""
    q = select(PromoCode).where(PromoCode.seller_id == listing.seller_id, PromoCode.code == clean_code(raw_code),
                                PromoCode.active.is_(True))
    promo = db.scalar(q.with_for_update() if lock else q)
    if promo is None:
        raise ApiError(404, "promo_not_found")
    if promo.ends_on is not None and promo.ends_on < today():
        raise ApiError(409, "promo_expired")
    if price_tiyn < promo.min_price_tiyn:
        raise ApiError(409, "promo_min_price")
    if uses(db, promo, buyer.id):
        raise ApiError(409, "promo_already_used")
    if promo.max_uses is not None and uses(db, promo) >= promo.max_uses:
        raise ApiError(409, "promo_used_up")
    return promo, discount(promo, price_tiyn)


def seller(user: User) -> User:
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    return user


@router.get("/me/promo-codes")
def list_codes(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(PromoCode).where(PromoCode.seller_id == seller(user).id, PromoCode.active.is_(True))
                      .order_by(PromoCode.id.desc())).all()
    return {"items": [promo_out(db, p) for p in rows]}


@router.post("/me/promo-codes", status_code=201)
def create_code(body: PromoIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    code = clean_code(body.code)
    if db.scalar(select(PromoCode.id).where(PromoCode.seller_id == seller(user).id, PromoCode.code == code,
                                            PromoCode.active.is_(True))):
        raise ApiError(409, "promo_exists")
    if body.ends_on is not None and body.ends_on < today():
        raise ApiError(422, "validation", "ends_on is in the past")
    promo = PromoCode(seller_id=user.id, code=code, percent=body.percent, amount_tiyn=body.amount_tiyn,
                      min_price_tiyn=body.min_price_tiyn, max_uses=body.max_uses, ends_on=body.ends_on)
    db.add(promo)
    db.commit()
    return promo_out(db, promo)


@router.delete("/me/promo-codes/{promo_id}")
def end_code(promo_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Stops the code for new orders; orders already placed keep their discount."""
    promo = db.get(PromoCode, promo_id)
    if promo is None or promo.seller_id != user.id:
        raise ApiError(404, "not_found")
    promo.active = False
    db.commit()
    return {"ended": True}


@router.get("/listings/{listing_id}/promo")
def check_code(listing_id: int, code: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """What the buyer would pay with this code, before ordering."""
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    promo, off = apply(db, code, listing, listing.price_tiyn, user)
    item = listing.price_tiyn - off
    return {"code": promo.code, "discount_tiyn": off, "item_price_tiyn": item,
            "total_tiyn": item + listing.delivery_price_tiyn}
