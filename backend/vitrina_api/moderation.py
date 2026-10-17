"""Automatic checks run when a seller publishes a listing.

A listing that trips any check goes to the "moderation" queue instead of the catalog, and staff approve it or
send it back with a reason the seller sees. The checks only flag; a person always makes the final call, so a
false positive costs a short wait, never a lost listing.
"""
from __future__ import annotations

import io
import logging
import re
import statistics

from PIL import Image
from sqlalchemy import select
from sqlalchemy.orm import Session

from vitrina_core.catalog import compute_bounds

from .models import Listing, Media
from .social import CONTACT_RE

log = logging.getLogger(__name__)

# Words that announce a copy of a branded shoe. Selling those is not allowed whatever the price.
REPLICA_RE = re.compile(
    r"\b(реплика|копия|копию|паль|палёные|палёнка|replica|fake|1:1|lux\s?copy|люкс\s?копия|зеркальн\w*|"
    r"көшірме|жасанды)\b", re.IGNORECASE)
# A price this far under the usual price for the same model, or under the category's cheapest quarter.
MODEL_PRICE_RATIO = 0.35
CATEGORY_PRICE_RATIO = 0.4
MODEL_MIN_SAMPLE = 5
# Two photos whose 64-bit difference hashes are this close are the same picture, even re-saved or resized.
PHASH_DISTANCE = 6
CHECKED_ANGLES = ("front", "outer", "inner", "back", "top", "sole", "label")

REASONS = {
    "contacts": ("Атауда не сипаттамада телефон, сілтеме не мессенджер бар. Байланыс тек VITRINA чатында.",
                 "В названии или описании есть телефон, ссылка или мессенджер. Связь только в чате VITRINA."),
    "replica": ("Мәтінде көшірме тауар туралы сөз бар. Көшірме аяқкиім сатуға болмайды.",
                "В тексте упоминается копия. Продавать копии обуви нельзя."),
    "low_price": ("Баға осы үлгінің әдеттегі бағасынан әлдеқайда төмен. Қызметкер тексереді.",
                  "Цена намного ниже обычной для этой модели. Сотрудник проверит."),
    "reused_photo": ("Фото басқа сатушының хабарландыруымен бірдей. Өз аяқкиіміңіздің суретін түсіріңіз.",
                     "Фото совпадает с объявлением другого продавца. Снимите свою пару."),
}


def dhash(data: bytes) -> str:
    """64-bit difference hash as 16 hex digits: survives re-encoding, resizing and small crops."""
    img = Image.open(io.BytesIO(data)).convert("L").resize((9, 8), Image.Resampling.LANCZOS)
    px = img.tobytes()
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (px[row * 9 + col] > px[row * 9 + col + 1])
    return f"{bits:016x}"


def distance(a: str, b: str) -> int:
    return (int(a, 16) ^ int(b, 16)).bit_count()


def ensure_hashes(db: Session, storage, listing: Listing) -> None:
    for m in listing.media:
        if m.phash is None and m.angle in CHECKED_ANGLES:
            try:
                m.phash = dhash(storage.read(m.original_url))
            except Exception:  # noqa: BLE001 - a photo we cannot read is not evidence of anything
                log.info("moderation: cannot hash %s", m.original_url)


def has_contacts(listing: Listing) -> bool:
    return any(CONTACT_RE.search(t or "") for t in (listing.title, listing.description, listing.defects))


def mentions_replica(listing: Listing) -> bool:
    return any(REPLICA_RE.search(t or "") for t in (listing.title, listing.description))


def suspiciously_cheap(db: Session, listing: Listing) -> bool:
    live = (Listing.status.in_(("published", "sold")), Listing.id != listing.id)
    if listing.brand and listing.model_name:
        same = db.scalars(select(Listing.price_tiyn).where(
            *live, Listing.brand == listing.brand, Listing.model_name == listing.model_name)).all()
        if len(same) >= MODEL_MIN_SAMPLE:
            return listing.price_tiyn < statistics.median(same) * MODEL_PRICE_RATIO
    prices = db.scalars(select(Listing.price_tiyn).where(*live, Listing.category == listing.category)).all()
    bounds = compute_bounds(listing.category, list(prices))
    return bounds is not None and listing.price_tiyn < bounds.mid_from * CATEGORY_PRICE_RATIO


def informative(h: str) -> bool:
    """A plain or nearly plain picture hashes to almost all zeros or ones and would match every other one."""
    return 8 <= int(h, 16).bit_count() <= 56


def reused_photo(db: Session, listing: Listing) -> bool:
    mine = [m.phash for m in listing.media if m.phash and informative(m.phash)]
    if not mine:
        return False
    others = db.scalars(select(Media.phash).join(Listing, Listing.id == Media.listing_id).where(
        Listing.seller_id != listing.seller_id, Media.phash.is_not(None),
        Listing.status.in_(("published", "sold", "moderation", "paused")))).all()
    return any(distance(a, b) <= PHASH_DISTANCE for a in mine for b in others if informative(b))


def check(db: Session, storage, listing: Listing) -> list[str]:
    """Reason codes for every check the listing fails; empty means it can go straight to the catalog."""
    ensure_hashes(db, storage, listing)
    db.flush()
    flags = [("contacts", has_contacts(listing)), ("replica", mentions_replica(listing)),
             ("low_price", suspiciously_cheap(db, listing)), ("reused_photo", reused_photo(db, listing))]
    return [code for code, hit in flags if hit]
