"""Finding shoes: catalog search, spelling help, search by photo, look-alikes and suggestions while typing."""
from __future__ import annotations

import collections
import threading
import time
from typing import Literal

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.catalog import BRAND_SYNONYMS, audiences_for, categories_for, is_filler, normalize_query, transliterate

from . import delivery_eta, visual
from .api_common import AUDIENCES
from .deps import current_user, get_db, get_storage, now_utc
from .errors import ApiError
from .models import ListingEmbedding, Listing, User
from .storage import MAX_UPLOAD_BYTES, Storage, normalize_image
from .serializers import LIGHT, listing_out, with_light_media
from .saved_search_routes import catalog_filter, fits_foot


router = APIRouter(prefix="/api/v1")


def sellers_in(db: Session, city: str) -> list[int]:
    """Sellers whose city is `city`, however they spelled it (Алматы, Almaty, Алма-Ата)."""
    want = delivery_eta.known_city(city)
    if want is None:
        return []
    rows = db.execute(select(User.id, User.city).where(User.is_seller.is_(True), User.city.is_not(None))).all()
    return [uid for uid, c in rows if delivery_eta.known_city(c) == want]


def page_of(db: Session, scored: list[tuple[float, int]]) -> list[tuple[float, Listing]]:
    """The listings of a ranked page, in its order. Ranking reads only ids and vectors: loading every listing on sale
    with its photos to rank them read the whole catalog for each search."""
    found = {listing.id: listing for listing in with_light_media(db, db.scalars(
        select(Listing).options(LIGHT).where(Listing.id.in_([lid for _, lid in scored]))).all())}
    return [(score, found[lid]) for score, lid in scored if lid in found]


@router.get("/listings")
def search_listings(q: str | None = None, category: str | None = None, brand: str | None = None,
                    condition: str | None = None, min_price_tiyn: int | None = None,
                    max_price_tiyn: int | None = None, size_cm: str | None = None,
                    sort: Literal["new", "price_asc", "price_desc"] = "new", seller_id: int | None = None,
                    sale: bool = False, city: str | None = Query(default=None, max_length=60),
                    color: str | None = Query(default=None, max_length=300),
                    audience: Literal[AUDIENCES] | None = None,  # type: ignore[valid-type]
                    limit: int = 20,
                    offset: int = 0, db: Session = Depends(get_db)):
    stmt = catalog_filter(select(Listing).where(Listing.status == "published"), q=q, category=category,
                          brand=brand, condition=condition, min_price_tiyn=min_price_tiyn,
                          max_price_tiyn=max_price_tiyn, size_cm=size_cm, color=color, audience=audience)
    if seller_id is not None:
        stmt = stmt.where(Listing.seller_id == seller_id)
    if sale:
        stmt = stmt.where(Listing.was_price_tiyn > Listing.price_tiyn, Listing.was_until > now_utc())
    if city:
        stmt = stmt.where(Listing.seller_id.in_(sellers_in(db, city)))
    order = {"new": (Listing.id.desc(),), "price_asc": (Listing.price_tiyn, Listing.id.desc()),
             "price_desc": (Listing.price_tiyn.desc(), Listing.id.desc())}[sort]
    rows = with_light_media(db, db.scalars(stmt.options(LIGHT).order_by(*order).limit(max(1, min(limit, 50)))
                                           .offset(max(0, offset))).all())
    out = {"items": [listing_out(db, r) for r in rows]}
    if not rows and q and offset == 0:
        out["did_you_mean"] = did_you_mean(db, q)
    # Already plain JSON values: sent as they are, without FastAPI walking all ~10 000 of them again (a fifth of
    # the time of a catalog page).
    return JSONResponse(out)


_VOCAB: dict[int, tuple[tuple, dict[str, str]]] = {}


def search_vocabulary(db: Session) -> dict[str, str]:
    """Every word on sale (normalized -> how to show it). Rebuilt only when the published catalog changes, which
    one cheap count tells, instead of reading every listing on each search that finds nothing."""
    version = tuple(db.execute(select(func.count(Listing.id), func.max(Listing.id), func.sum(Listing.price_tiyn))
                               .where(Listing.status == "published")).one())
    key = id(db.get_bind())
    cached = _VOCAB.get(key)
    if cached and cached[0] == version:
        return cached[1]
    vocab: dict[str, str] = {}
    for text in db.scalars(select(Listing.search_text).where(Listing.status == "published")):
        for w in text.split():
            vocab.setdefault(w, w)
    for brand in db.scalars(select(Listing.brand).where(Listing.status == "published", Listing.brand.is_not(None))):
        for w in brand.split():
            vocab[normalize_query(w)] = w  # show brands the way sellers write them
    _VOCAB[key] = (version, vocab)
    return vocab


def did_you_mean(db: Session, q: str) -> str | None:
    """When a search finds nothing, the nearest spelling that does: 'nkie air' -> 'Nike air'. Words are matched
    against what is on sale now, so the hint never leads to another empty page."""
    import difflib
    vocab = search_vocabulary(db)
    words, changed = [], False
    for w in normalize_query(q).split():
        # "сапоги" and "для" are words people use, not typos of something on sale
        if w in vocab or len(w) < 3 or is_filler(w) or categories_for(w) or audiences_for(w):
            words.append(vocab.get(w, w))
            continue
        near = difflib.get_close_matches(w, list(vocab), n=1, cutoff=0.75)
        if not near:
            return None
        words.append(vocab[near[0]])
        changed = True
    if not changed:
        return None
    fixed = " ".join(words)
    hits = catalog_filter(select(Listing.id).where(Listing.status == "published"), q=fixed).limit(1)
    return fixed if db.scalar(hits) is not None else None


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

    def give_back(self, key: str) -> None:
        """Takes back the last hit of `key`: what it was spent on did not happen after all."""
        with self._lock:
            if self._hits.get(key):
                self._hits[key].pop()


IMAGE_SEARCH_PER_MINUTE = 20
# Shape-only cosine. Lower than SUGGEST_MIN_SHAPE: the buyer's photo is not cut out (floor, hand, bed around the
# shoe) while listing vectors are, so true matches score lower. Not yet measured on real phone photos.
IMAGE_MIN_SHAPE = 0.50


@router.post("/search/image")
def search_by_image(request: Request, file: UploadFile = File(...), category: str | None = None,
                          size_cm: str | None = None, limit: int = 20, db: Session = Depends(get_db)):
    """Listings that look like the uploaded photo, most similar first. The photo is not stored."""
    embed = request.app.state.embedder
    if embed is None:
        raise ApiError(503, "image_search_off")
    client = request.client.host if request.client else "unknown"
    if not request.app.state.image_search_limiter.allow(client, time.monotonic()):
        raise ApiError(429, "rate_limited")
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    import numpy as np
    query = embed(normalize_image(data))
    stmt = (select(Listing.id, ListingEmbedding.vector).join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
            .where(Listing.status == "published", ListingEmbedding.model == visual.MODEL_NAME))
    if category:
        stmt = stmt.where(Listing.category == category)
    if size_cm:
        stmt = stmt.where(fits_foot(size_cm))
    # Shape decides whether it is the same kind of thing at all; a photo of a cup must not bring "similar" shoes.
    shape_dims = query.size - visual.COLOR_BINS
    query_shape = query[:shape_dims] / (np.linalg.norm(query[:shape_dims]) + 1e-8)
    # Brute force is fine at MVP scale; move to pgvector once the catalogue passes ~50k listings.
    scored = []
    for lid, vec in db.execute(stmt):
        v = np.frombuffer(vec, np.float32)
        shape = float(v[:shape_dims] @ query_shape) / (float(np.linalg.norm(v[:shape_dims])) + 1e-8)
        if shape >= IMAGE_MIN_SHAPE:
            scored.append((float(v @ query), lid))
    scored = sorted(scored, key=lambda t: -t[0])[:max(1, min(limit, 50))]
    return {"items": [{**listing_out(db, listing), "similarity": round(score, 3)}
                      for score, listing in page_of(db, scored)]}


SUGGEST_MIN_SHAPE = 0.70  # shape-only cosine; same model in another colour scores ~0.8, unrelated objects ~0.4
SUGGEST_NEIGHBOURS = 5


class SuggestIn(BaseModel):
    photo_url: str = Field(max_length=500)


@router.post("/listings/suggest")
def suggest_details(body: SuggestIn, request: Request, user: User = Depends(current_user),
                    db: Session = Depends(get_db), storage: Storage = Depends(get_storage)):
    """Brand, model and category to offer the seller, read off look-alike listings already on VITRINA.

    Only shape counts (the colour part is dropped), since the same model comes in many colours.
    Each field is offered only when the neighbours agree on it; the seller decides whether to use it."""
    embed = request.app.state.embedder
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    if embed is None:
        raise ApiError(503, "image_search_off")
    if not storage.owns(body.photo_url, user.id):
        raise ApiError(422, "foreign_media")
    import numpy as np
    full = embed(storage.read(body.photo_url))
    shape_dims = full.size - visual.COLOR_BINS
    query = full[:shape_dims] / (np.linalg.norm(full[:shape_dims]) + 1e-8)
    rows = db.execute(select(Listing.id, ListingEmbedding.vector)
                      .join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
                      .where(Listing.status.in_(("published", "sold")), ListingEmbedding.model == visual.MODEL_NAME))
    scored = []
    for lid, vec in rows:
        shape = np.frombuffer(vec, np.float32)[:shape_dims]
        score = float(shape @ query) / (float(np.linalg.norm(shape)) + 1e-8)
        if score >= SUGGEST_MIN_SHAPE:
            scored.append((score, lid))
    near = page_of(db, sorted(scored, key=lambda t: -t[0])[:SUGGEST_NEIGHBOURS])

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


@router.get("/listings/{listing_id}/similar")
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
    rows = db.execute(select(Listing.id, ListingEmbedding.vector)
                      .join(ListingEmbedding, ListingEmbedding.listing_id == Listing.id)
                      .where(Listing.status == "published", Listing.id != listing_id,
                             ListingEmbedding.model == visual.MODEL_NAME))
    scored = sorted(((float(np.frombuffer(vec, np.float32) @ query), lid) for lid, vec in rows),
                    key=lambda t: -t[0])[:max(1, min(limit, 20))]
    return {"items": [{**listing_out(db, other), "similarity": round(score, 3)} for score, other in page_of(db, scored)]}


SUGGESTIONS = 8


def suggestion_keys(text: str) -> set[str]:
    """Forms a typed prefix may match: brand aliases mapped (найк -> nike) and plain transliteration (найк -> naik)."""
    return {normalize_query(text), transliterate(" ".join(text.lower().split()))}


def starts_a_word(key: str, typed: str) -> bool:
    return key.startswith(typed) or f" {typed}" in key


@router.get("/search/suggest")
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
