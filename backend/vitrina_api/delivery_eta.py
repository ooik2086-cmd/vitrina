"""When a pair would arrive: the seller's own usual time to ship plus a transit estimate between the two cities.

Until a delivery partner gives real quotes, transit is estimated from the straight-line distance between city
centres, so the app always says "about". Handling time is the median of the seller's last shipped orders, from
payment to shipping; a seller with no history gets the two days they are allowed to take.
"""
from __future__ import annotations

import math
import statistics
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import services
from .deps import get_db, now_utc, optional_user
from .errors import ApiError
from .models import Listing, Order, OrderEvent, User

router = APIRouter(prefix="/api/v1")

ALMATY = timezone(timedelta(hours=5))
DEFAULT_HANDLING_DAYS = 2
HISTORY = 20  # how many of the seller's latest shipped orders count

# name: (latitude, longitude, other spellings people type)
CITIES: dict[str, tuple[float, float, tuple[str, ...]]] = {
    "Алматы": (43.24, 76.89, ("almaty", "алма-ата", "алмата")),
    "Астана": (51.17, 71.45, ("astana", "нұр-сұлтан", "нур-султан", "nur-sultan")),
    "Шымкент": (42.32, 69.59, ("shymkent", "чимкент")),
    "Қарағанды": (49.81, 73.09, ("караганда", "karaganda", "qaragandy")),
    "Ақтөбе": (50.28, 57.17, ("актобе", "aktobe", "aqtobe")),
    "Тараз": (42.90, 71.37, ("taraz",)),
    "Павлодар": (52.29, 76.97, ("pavlodar",)),
    "Өскемен": (49.95, 82.61, ("усть-каменогорск", "oskemen", "ust-kamenogorsk")),
    "Семей": (50.41, 80.23, ("семипалатинск", "semey")),
    "Атырау": (47.11, 51.92, ("atyrau",)),
    "Қостанай": (53.21, 63.63, ("костанай", "kostanay", "qostanay")),
    "Қызылорда": (44.85, 65.51, ("кызылорда", "kyzylorda", "qyzylorda")),
    "Орал": (51.23, 51.37, ("уральск", "oral", "uralsk")),
    "Петропавл": (54.87, 69.15, ("петропавловск", "petropavl", "petropavlovsk")),
    "Ақтау": (43.65, 51.17, ("актау", "aktau", "aqtau")),
    "Түркістан": (43.30, 68.25, ("туркестан", "turkistan", "turkestan")),
    "Көкшетау": (53.28, 69.39, ("кокшетау", "kokshetau")),
    "Талдықорған": (45.02, 78.37, ("талдыкорган", "taldykorgan")),
    "Екібастұз": (51.73, 75.32, ("экибастуз", "ekibastuz")),
    "Жезқазған": (47.78, 67.71, ("жезказган", "zhezkazgan")),
    "Қонаев": (43.87, 77.07, ("конаев", "капшагай", "konaev")),
}
_LOOKUP = {k.lower(): k for k in CITIES} | {alias: k for k, (_, _, aliases) in CITIES.items() for alias in aliases}


def known_city(text: str | None) -> str | None:
    if not text:
        return None
    key = text.strip().lower().removeprefix("г.").removeprefix("қ.").strip()
    return _LOOKUP.get(key)


def km_between(a: str, b: str) -> float:
    (la1, lo1, _), (la2, lo2, _) = CITIES[a], CITIES[b]
    p1, p2, dl = math.radians(la1), math.radians(la2), math.radians(lo2 - lo1)
    c = math.sin(p1) * math.sin(p2) + math.cos(p1) * math.cos(p2) * math.cos(dl)
    return 6371 * math.acos(max(-1.0, min(1.0, c)))


def transit_days(origin: str, dest: str) -> tuple[int, int]:
    """Courier days, fewest to most. Same city: next day; then a day per ~700 km on top of two."""
    if origin == dest:
        return 1, 2
    low = 2 + int(km_between(origin, dest) // 700)
    return low, low + 2


def handling_days(db: Session, seller_id: int) -> int:
    orders = db.scalars(select(Order.id).where(Order.seller_id == seller_id, Order.tracking_number.is_not(None))
                        .order_by(Order.id.desc()).limit(HISTORY)).all()
    hours = []
    for oid in orders:
        events = {e.to_status: services.aware(e.at) for e in db.scalars(
            select(OrderEvent).where(OrderEvent.order_id == oid, OrderEvent.to_status.in_(("PAID", "SHIPPED"))))}
        if "PAID" in events and "SHIPPED" in events:
            hours.append((events["SHIPPED"] - events["PAID"]).total_seconds() / 3600)
    if not hours:
        return DEFAULT_HANDLING_DAYS
    return round(statistics.median(hours) / 24)  # a few hours is shipping the same day


def estimate(db: Session, listing: Listing, dest: str, *, today: date) -> dict | None:
    seller = db.get(User, listing.seller_id)
    origin = known_city(seller.city if seller else None)
    if origin is None:
        return None
    start = today
    if seller.away_until and seller.away_until >= today:
        start = seller.away_until + timedelta(days=1)  # nothing ships while the shop is away
    ship = handling_days(db, seller.id)
    low, high = transit_days(origin, dest)
    return {"city": dest, "from_city": origin, "handling_days": ship,
            "earliest": (start + timedelta(days=ship + low)).isoformat(),
            "latest": (start + timedelta(days=ship + high)).isoformat()}


def viewer_city(user: User | None) -> str | None:
    if user is None:
        return None
    if user.last_delivery:
        import json
        city = known_city(json.loads(user.last_delivery).get("city"))
        if city:
            return city
    return known_city(user.city)


@router.get("/listings/{listing_id}/delivery-estimate")
def delivery_estimate(listing_id: int, city: str | None = Query(default=None, max_length=60),
                      user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    """About when the pair would arrive in `city`, or in the city this person last ordered to."""
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status not in ("published", "paused", "sold"):
        raise ApiError(404, "not_found")
    dest = known_city(city) if city else viewer_city(user)
    if dest is None:
        return {"estimate": None, "cities": list(CITIES)}
    now: datetime = now_utc()
    return {"estimate": estimate(db, listing, dest, today=now.astimezone(ALMATY).date()), "cities": list(CITIES)}
