"""Saved searches, the catalog filter they share with search, and telling followers about a new listing."""
from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.catalog import normalize_query
from vitrina_core.colors import PARTS, color_list, color_query, matching_colors

from . import services
from . import promo
from .deps import current_user, get_db, now_utc
from .errors import ApiError
from .models import Follow, SavedSearch, Favorite, Listing, ListingSize, User
from .serializers import cm_to_mm, listing_out


router = APIRouter(prefix="/api/v1")


def catalog_filter(stmt, *, q: str | None = None, category: str | None = None, brand: str | None = None,
                   condition: str | None = None, min_price_tiyn: int | None = None,
                   max_price_tiyn: int | None = None, size_cm: str | None = None, color: str | None = None):
    """The catalog's filters, shared by search and by saved-search alerts so both agree on what matches."""
    if q:
        # Colour words become the stored Kazakh name first: "черные" and "black" find "қара".
        for token in normalize_query(color_query(q)).split():
            stmt = stmt.where(Listing.search_text.contains(token))
    if category:
        stmt = stmt.where(Listing.category == category)
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


MAX_SAVED_SEARCHES = 10
SEARCH_FIELDS = ("q", "category", "brand", "condition", "min_price_tiyn", "max_price_tiyn", "size_cm", "color")


class SavedSearchIn(BaseModel):
    q: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=30)
    brand: str | None = Field(default=None, max_length=60)
    condition: str | None = Field(default=None, max_length=200)
    min_price_tiyn: int | None = Field(default=None, ge=0)
    max_price_tiyn: int | None = Field(default=None, ge=0)
    size_cm: str | None = Field(default=None, max_length=8)
    color: str | None = Field(default=None, max_length=300)

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
            *[SavedSearch.color.contains(c, autoescape=True) for c in {listing.color, *PARTS.get(listing.color, ())}]))
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


@router.post("/favorites/{listing_id}", status_code=204)
def add_favorite(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if db.get(Listing, listing_id) is None:
        raise ApiError(404, "not_found")
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
def list_favorites(user: User = Depends(current_user), db: Session = Depends(get_db)):
    ids = db.scalars(select(Favorite.listing_id).where(Favorite.user_id == user.id)).all()
    return {"items": [listing_out(db, db.get(Listing, i)) for i in ids]}
