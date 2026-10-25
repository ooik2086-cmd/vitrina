"""Saved searches, the catalog filter they share with search, and telling followers about a new listing."""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import audiences_for, categories_for, is_filler, normalize_query
from vitrina_core.colors import PARTS, color_list, color_query, matching_colors

from . import services
from . import promo
from .deps import current_user, get_db, now_utc
from .errors import ApiError
from .api_common import AUDIENCES
from .models import Follow, SavedSearch, Favorite, Listing, ListingSize, User
from .serializers import LIGHT, cm_to_mm, listing_out, with_light_media


router = APIRouter(prefix="/api/v1")


def catalog_filter(stmt, *, q: str | None = None, category: str | None = None, brand: str | None = None,
                   condition: str | None = None, min_price_tiyn: int | None = None,
                   max_price_tiyn: int | None = None, size_cm: str | None = None, color: str | None = None,
                   audience: str | None = None):
    """The catalog's filters, shared by search and by saved-search alerts so both agree on what matches."""
    if q:
        stmt = stmt.where(*query_words(q))
    if category:
        stmt = stmt.where(Listing.category == category)
    if audience:
        stmt = stmt.where(or_(*for_whom(audience)))
    if brand:
        stmt = stmt.where(Listing.search_text.contains(normalize_query(brand)))
    if condition:  # one value or a comma-separated list
        stmt = stmt.where(Listing.condition.in_([c for c in condition.split(",") if c]))
    if min_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn >= min_price_tiyn)
    if max_price_tiyn is not None:
        stmt = stmt.where(Listing.price_tiyn <= max_price_tiyn)
    # One colour or a comma-separated list, in any of the words the colour list knows; blank parts ask for nothing.
    if color and (names := color_list(color)):
        stmt = stmt.where(Listing.color.in_(matching_colors(names)))
    if size_cm:
        mm = cm_to_mm(size_cm)
        stmt = stmt.where(Listing.id.in_(select(ListingSize.listing_id).where(
            ListingSize.quantity > 0, ListingSize.insole_mm.between(mm - 5, mm + 5))))
    return stmt


def for_whom(audience: str) -> list:
    """Pairs for this audience: a unisex pair is also men's and women's, and a pair in the children's category is
    children's whether or not the seller said so."""
    if audience == "kids":
        return [Listing.audience == "kids", Listing.category == "kids"]
    return [Listing.audience.in_((audience, "unisex") if audience in ("men", "women") else (audience,))]


def query_words(q: str) -> list:
    """What the words typed ask for, every one of them. Colour words become the stored Kazakh name first: "черные"
    and "black" find "қара". A word for a kind of footwear or for whom it is made also finds the pairs filed so,
    though their titles do not say it: "сапоги" finds a pair titled "Етік" in the boots category. Words for kinds
    are alternatives to each other ("рабочие ботинки": work shoes, or boots), as are words for whom; the two sets
    narrow each other ("детские сандалии": sandals, for children). Words that ask for nothing are left out."""
    kinds: dict[str, list[str]] = {}
    whom: dict[str, list[str]] = {}
    found = []
    for token in normalize_query(color_query(q)).split():
        if is_filler(token):
            continue
        if audiences := audiences_for(token):
            whom[token] = audiences
        elif categories := categories_for(token):
            kinds[token] = categories
        else:
            found.append(Listing.search_text.contains(token))
    if kinds:
        found.append(or_(Listing.category.in_({c for cs in kinds.values() for c in cs}),
                         *[Listing.search_text.contains(t) for t in kinds]))
    if whom:
        found.append(or_(*[w for a in {a for aa in whom.values() for a in aa} for w in for_whom(a)],
                         *[Listing.search_text.contains(t) for t in whom]))
    return found


MAX_SAVED_SEARCHES = 10
SEARCH_FIELDS = ("q", "category", "brand", "condition", "min_price_tiyn", "max_price_tiyn", "size_cm", "color",
                 "audience")


class SavedSearchIn(BaseModel):
    q: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=30)
    brand: str | None = Field(default=None, max_length=60)
    condition: str | None = Field(default=None, max_length=200)
    min_price_tiyn: int | None = Field(default=None, ge=0)
    max_price_tiyn: int | None = Field(default=None, ge=0)
    size_cm: str | None = Field(default=None, max_length=8)
    color: str | None = Field(default=None, max_length=300)
    audience: Literal[AUDIENCES] | None = None  # type: ignore[valid-type]

    # In one spelling before the length is checked: a Kazakh name can be longer than the word typed for it.
    _color = field_validator("color", mode="before")(
        lambda v: (",".join(color_list(v)) or None) if isinstance(v, str) else v)


def search_values(source) -> dict:
    values = {f: getattr(source, f) for f in SEARCH_FIELDS}
    values = {k: (v.strip() or None) if isinstance(v, str) else v for k, v in values.items()}
    if values["color"]:
        values["color"] = ",".join(color_list(values["color"])) or None  # one spelling, so equal searches compare equal
    return values


def saved_search_out(s: SavedSearch) -> dict:
    return {"id": s.id, **search_values(s), "created_at": services.aware(s.created_at).isoformat()}


def announce(db: Session, listing: Listing) -> None:
    """Tell the shop's followers and buyers whose saved searches match a listing, once, when it first goes on sale."""
    if listing.announced_at is not None:
        return
    listing.announced_at = now_utc()
    db.flush()
    told: set[int] = {listing.seller_id}
    price = promo.format_tenge(listing.price_tiyn)
    seller = db.get(User, listing.seller_id)
    shop = seller.shop_name or "VITRINA"
    for follower in db.scalars(select(Follow.user_id).join(User, User.id == Follow.user_id).where(
            Follow.seller_id == listing.seller_id, User.is_blocked.is_(False)).order_by(Follow.id)).all():
        if follower not in told:
            told.add(follower)  # a follower who also has a matching saved search hears about it once
            services.notify(db, follower, "followed_shop", f"«{shop}» жаңа тауар қойды: «{listing.title}», {price}",
                            f"«{shop}» выставил новый товар: «{listing.title}», {price}",
                            f"“{shop}” listed something new: “{listing.title}”, {price}", listing_id=listing.id)
    # Only searches this listing can match on its plain fields are checked one by one; with many saved searches
    # checking every one of them made publishing slow.
    candidates = select(SavedSearch).join(User, User.id == SavedSearch.user_id).where(
        User.is_blocked.is_(False),
        or_(SavedSearch.category.is_(None), SavedSearch.category == "", SavedSearch.category == listing.category),
        or_(SavedSearch.min_price_tiyn.is_(None), SavedSearch.min_price_tiyn <= listing.price_tiyn),
        or_(SavedSearch.max_price_tiyn.is_(None), SavedSearch.max_price_tiyn >= listing.price_tiyn),
        # A colour search names this colour or one it is made of (a looser test; the exact one is below).
        or_(SavedSearch.color.is_(None), SavedSearch.color == "",
            *[SavedSearch.color.contains(c, autoescape=True) for c in {listing.color, *PARTS.get(listing.color, ())}]),
        # A search for whom names one this pair is for (as for_whom decides).
        or_(SavedSearch.audience.is_(None), SavedSearch.audience.in_(
            {listing.audience, *(("men", "women") if listing.audience == "unisex" else ()),
             *(("kids",) if listing.category == "kids" else ())} - {None})))
    for saved in db.scalars(candidates.order_by(SavedSearch.id)).all():
        if saved.user_id in told:
            continue
        match = catalog_filter(select(Listing.id).where(Listing.id == listing.id), **search_values(saved))
        if db.scalar(match) is not None:
            told.add(saved.user_id)
            services.notify(db, saved.user_id, "saved_search", f"Іздеуіңізге сай жаңа тауар: «{listing.title}», {price}",
                            f"Новый товар по вашему поиску: «{listing.title}», {price}",
                            f"New match for your search: “{listing.title}”, {price}", listing_id=listing.id)


@router.post("/saved-searches", status_code=201)
def save_search(body: SavedSearchIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    values = search_values(body)
    if not any(v is not None for v in values.values()):
        raise ApiError(422, "validation", "a saved search needs at least one filter")
    if values["size_cm"]:
        cm_to_mm(values["size_cm"])  # same validation as the catalog
    mine = db.scalars(select(SavedSearch).where(SavedSearch.user_id == user.id)).all()
    same = next((s for s in mine if search_values(s) == values), None)
    if same:
        return saved_search_out(same)
    if len(mine) >= MAX_SAVED_SEARCHES:
        raise ApiError(409, "saved_search_limit")
    saved = SavedSearch(user_id=user.id, **values)
    db.add(saved)
    db.commit()
    return saved_search_out(saved)


@router.get("/saved-searches")
def list_saved_searches(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(SavedSearch).where(SavedSearch.user_id == user.id).order_by(SavedSearch.id.desc())).all()
    return {"items": [saved_search_out(s) for s in rows]}


@router.delete("/saved-searches/{search_id}", status_code=204)
def delete_saved_search(search_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    saved = db.get(SavedSearch, search_id)
    if saved is None or saved.user_id != user.id:
        raise ApiError(404, "not_found")
    db.delete(saved)
    db.commit()


# What anyone may see of a listing, as GET /listings/{id} shows it; the seller sees their own whatever its state.
SHOWN = ("published", "sold")


@router.post("/favorites/{listing_id}", status_code=204)
def add_favorite(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    if listing is None or not (listing.status in SHOWN or listing.seller_id == user.id):
        raise ApiError(404, "not_found")  # as GET /listings/{id}: a draft or a hidden pair is nobody else's to see
    db.add(Favorite(user_id=user.id, listing_id=listing_id))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()


@router.delete("/favorites/{listing_id}", status_code=204)
def remove_favorite(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    fav = db.scalar(select(Favorite).where(Favorite.user_id == user.id, Favorite.listing_id == listing_id))
    if fav:
        db.delete(fav)
        db.commit()


@router.get("/favorites")
def list_favorites(before: int | None = Query(default=None, ge=1, le=2**31 - 1),
                   limit: int = Query(default=100, ge=1, le=100),
                   user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The newest saved first, a page at a time: a long list of favourites with every 360° frame is never one response.
    next_before is the cursor for the next page (null after the last), by when it was saved, not by offset, so a heart
    tapped meanwhile never repeats or skips one; a page may hold fewer items than it counted when a listing is gone, or
    no longer on show (paused, hidden by a moderator), as its own page would not open either."""
    q = select(Favorite.id, Favorite.listing_id).where(Favorite.user_id == user.id)
    if before is not None:
        q = q.where(Favorite.id < before)
    saved = db.execute(q.order_by(Favorite.id.desc()).limit(limit + 1)).all()
    saved, more = saved[:limit], len(saved) > limit
    ids = [s.listing_id for s in saved]
    found = {listing.id: listing for listing in with_light_media(db, db.scalars(
        select(Listing).options(LIGHT).where(Listing.id.in_(ids),
                                             or_(Listing.status.in_(SHOWN), Listing.seller_id == user.id))).all())}
    return {"items": [listing_out(db, found[i]) for i in ids if i in found],
            "next_before": saved[-1].id if more else None}
