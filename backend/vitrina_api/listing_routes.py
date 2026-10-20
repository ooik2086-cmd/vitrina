"""Listings: creating, editing, publishing, photos, search, image search and the seller's shop tools."""
from __future__ import annotations

import io
import json
from dataclasses import dataclass
from datetime import timedelta
from types import SimpleNamespace
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Depends, File, Request, UploadFile
from PIL import Image
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from sqlalchemy.orm.attributes import set_committed_value

from vitrina_core.catalog import Authenticity, Condition, normalize_query
from vitrina_core.colors import canonical_color
from vitrina_core.orders import OrderStatus as S

from . import services
from . import cutout, moderation, promo, visual
from .config import Settings
from .deps import current_user, get_db, get_settings, get_storage, now_utc, optional_user
from .errors import ApiError
from .social import size_fit
from .models import (PriceChange, StockAlert, ListingDailyViews, ListingEmbedding, ListingReport, Favorite, Listing,
                     ListingSize, Media, Order, User)
from .storage import DETAIL_SIDE_PX, MAX_SIDE_PX, MAX_UPLOAD_BYTES, Storage, normalize_image
from .api_common import ALMATY, DEFECT_REQUIRED, MAX_LISTING_MEDIA, MAX_LISTING_SIZES, MIN_SPIN_FRAMES, log
from .schemas import ListingIn, ListingPatch, PhotoIn, ReportIn
from .serializers import (angle_frames, cm_to_mm, cover_frame, cover_photo, listing_out, mark_price_change, one_turn,
                          photo_snapshot, showcase_parts, side_photo, was_price)
from .saved_search_routes import announce


router = APIRouter(prefix="/api/v1")


def search_text(title: str, brand: str | None, model_name: str | None, color: str, category: str) -> str:
    return normalize_query(" ".join(filter(None, [title, brand, model_name, color, category])))


@router.post("/media", status_code=201)
def upload_photo(file: UploadFile = File(...), detail: bool = False, user: User = Depends(current_user),
                       storage: Storage = Depends(get_storage)):
    """[detail] keeps a top, sole or close-up photo larger, so its stitching is still sharp when zoomed in."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    return {"url": storage.put(normalize_image(data, DETAIL_SIDE_PX if detail else MAX_SIDE_PX), owner_id=user.id)}


# Labels and defect close-ups stay as taken: their surroundings are part of what they prove. A close-up of the
# stitching fills the photo, so there is no background to remove and the model would only eat into the shoe.
CUTOUT_ANGLES = {"front", "outer", "inner", "back", "top", "sole", "frame"}


# Listings whose seller can still change the photos and is told about one the model found no shoe in.
STILL_WORKED_ON = ("draft", "moderation", "published", "paused", "rejected")


def cutout_parts(media: list) -> list[list]:
    """The photos cut out together: each part of the 360° turn (see showcase_parts), and each other showcase photo
    on its own."""
    return showcase_parts(media) + [[m] for m in media if m.angle in CUTOUT_ANGLES and m.angle != "frame"]


def can_cut(todo: list, model: str, storage: Storage) -> bool:
    """False when a photo of these is known not to cut out: the model found no shoe in it, or it is not ours."""
    return not any(m.no_cutout == model or not storage.owns(m.original_url) for m in todo)


def cutout_model(segment) -> str:
    """The name photos the model found no shoe in are marked with (Media.no_cutout)."""
    return getattr(segment, "name", None) or "segmenter"


def cutout_listing(state, listing_id: int) -> int:
    """Background job: add a transparent-background version of each showcase photo of one listing.

    A part of the 360° turn (see showcase_parts) shows its cut-outs only when every frame of it has one, and
    otherwise the photos as taken, whose small copies must then be of those photos. So its frames are kept cut out
    all together or not at all: a part with a frame that cannot be cut out keeps the photos as taken, and the
    frame is marked so that later runs (the backfill) do not cut the whole part out again only to throw it away."""
    segment, storage = state.segmenter, state.storage
    if segment is None:
        return 0
    model = cutout_model(segment)
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return 0
        # The photos as they were read: the seller may change them while the shoes are cut out, which takes a while.
        parts = [[SimpleNamespace(id=m.id, original_url=m.original_url, processed_url=m.processed_url,
                                  no_cutout=m.no_cutout, angle=m.angle) for m in part]
                 for part in cutout_parts(listing.media)]
        seller = listing.seller_id
        db.rollback()
    done = 0
    for part in parts:
        todo = [m for m in part if not m.processed_url]
        if not todo:
            continue
        cuts: dict[int, str] = {}
        failed = None
        if not can_cut(todo, model, storage):
            failed = True  # known already: nothing to cut out again
        for m in todo if failed is None else ():
            try:
                result = cutout.process_photo(storage.read(m.original_url), segment)
            except Exception:  # may work next time: the storage was away, say
                log.exception("cutout failed for %s", m.original_url)
                failed = True
                break
            if result is None:  # the model finds no shoe in it, and would not next time either
                failed = m
                break
            cuts[m.id] = storage.put(result, owner_id=seller, ext="webp")
        with state.sessions() as db:
            done += _settle_cutouts(db, storage, listing_id, part, {} if failed else cuts,
                                    failed.id if isinstance(failed, SimpleNamespace) else None, model)
    return done


def _settle_cutouts(db: Session, storage: Storage, listing_id: int, part: list, cuts: dict[int, str],
                    no_shoe: int | None, model: str) -> int:
    """Writes one part's cut-outs once the listing is locked (see lock_fresh), only onto its photos as they are
    now: when the seller changed a part of the turn meanwhile, the job for the new photos decides it. Leaves no
    part of the turn with some frames cut out and some not. Returns how many cut-outs were kept."""
    db.execute(select(Listing.id).where(Listing.id == listing_id).with_for_update())
    listing = db.get(Listing, listing_id)
    if listing is None:
        return 0
    read = {m.id: m.original_url for m in part}
    if part[0].angle == "frame":
        now = next((p for p in showcase_parts(listing.media) if [m.id for m in p] == list(read)), None)
    else:
        now = [m for m in listing.media if m.id in read]
    if not now or any(m.original_url != read[m.id] for m in now):
        db.rollback()
        return 0
    kept = 0
    vector_of = embedded_photo(storage, listing) if part[0].angle != "frame" else None
    for m in now:
        if m.id == no_shoe:
            seller = db.get(User, listing.seller_id)
            if (not any(x.no_cutout for x in listing.media) and listing.status in STILL_WORKED_ON
                    and seller is not None and seller.deleted_at is None):
                # Told once, on the first photo with no shoe found, while the seller can still do something about
                # it (not for a sold listing the backfill reaches); the listing's page names the photos.
                t = listing.title
                if part[0].angle == "frame":
                    texts = (f"«{t}»: 360° айналымның бір кадрында аяқкиім табылмады, сондықтан айналымның фоны "
                             f"алынбайды. Айналымды тауар бетінде қайта түсіріңіз.",
                             f"«{t}»: на одном из кадров обзора 360° не найдена обувь, поэтому фон обзора не "
                             f"удаляется. Переснимите обзор на странице товара.",
                             f"“{t}”: no shoe was found in a frame of the 360° view, so the view keeps its "
                             f"background. Retake the view on the listing's page.")
                else:
                    texts = (f"«{t}»: фотода аяқкиім табылмады, сондықтан оның фоны алынбайды. Қай фото екенін "
                             f"тауар бетінің фото бөлімінен көріңіз.",
                             f"«{t}»: на фото не найдена обувь, поэтому фон на нём не удаляется. Какое это фото, "
                             f"видно в разделе фото на странице товара.",
                             f"“{t}”: no shoe was found in a photo, so its background is not removed. The photos "
                             f"section of the listing's page shows which one.")
                services.notify(db, listing.seller_id, "photo_no_shoe", *texts, listing_id=listing_id)
            m.no_cutout = model
        if m.id in cuts and not m.processed_url:
            m.processed_url, m.thumb_url, m.no_cutout = cuts[m.id], None, None
            kept += 1
    if kept and vector_of is not None and vector_of.id in cuts:
        # The search vector was made from the photo as taken: gone until the next one is made from the cut-out,
        # so that the backfill sees it missing should that fail.
        db.execute(delete(ListingEmbedding).where(ListingEmbedding.listing_id == listing_id))
    if part[0].angle == "frame" and any(m.processed_url for m in now) and not all(m.processed_url for m in now):
        # Cut out on an earlier run, or by another job, while another frame is not: the photos as taken, with new
        # small copies of them to match. Dropped cut-outs go with the orphans sweep.
        log.info("listing %s: %d of %d frames of a part of its turn not cut out; it shows the photos as taken",
                 listing_id, sum(not m.processed_url for m in now), len(now))
        for m in now:
            if m.processed_url:
                m.processed_url, m.thumb_url = None, None
        kept = 0
    db.commit()
    return kept


def embedded_photo(storage: Storage, listing: Listing):
    """The photo the search-by-photo vector is made from: the first side photo in our storage, cut out or not."""
    photos = sorted((m for m in listing.media if m.angle in SIDE_ORDER), key=lambda m: SIDE_ORDER.index(m.angle))
    return next((m for m in photos if storage.owns(m.processed_url or m.original_url)), None)


SIDE_ORDER = ("front", "outer", "inner", "back")


def embed_listing(state, listing_id: int) -> bool:
    """Background job: store the search-by-photo vector of a listing's main photo."""
    embed, storage = state.embedder, state.storage
    if embed is None:
        return False
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return False
        photo = embedded_photo(storage, listing)
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
        urls = [m.processed_url or m.original_url for m in chosen]
        title, price, style, seller = (listing.title, listing.price_tiyn, listing.showcase_style,
                                       listing.seller_id)
        db.rollback()  # nothing held open while the photos are read and the video is made (see PG_LIMITS)
    url, state_ = None, "failed"
    try:
        photos = [Image.open(io.BytesIO(storage.read(u))) for u in urls if storage.owns(u)]
        video = promo.render_video(photos, title=title, price=promo.format_tenge(price), style=style, lang=lang,
                                   spin=spin)
        url, state_ = storage.put(video, owner_id=seller, ext="mp4"), "ready"
    except Exception:
        log.exception("promo video failed for listing %s", listing_id)
    with state.sessions() as db:
        db.execute(update(Listing).where(Listing.id == listing_id)
                   .values(promo_state=state_, **({"promo_url": url} if url else {})))
        db.commit()
    return state_ == "ready"


PROMO_ANGLES = ("outer", "front", "inner", "back", "top")


# The cover angles a 360° turn passes through; a sole, a label or a close-up is no frame of it.
TURN_ANGLES = {"front", "outer", "inner", "back"}


@dataclass
class TurnMatches:
    """What a comparison found, by address, as the photos were when it ran."""
    cover: tuple[str, str] | None  # (frame, cover photo)
    sides: dict[str, tuple[str, str]]  # side: (frame, side photo)
    tried: bool  # some side photo was compared, found or not


def _turn_match_due(storage: Storage, listing: Listing):
    """What match_turn_frames has to look for: the frames, the cover and the side photos to match, and one turn;
    None when there is nothing to match yet or any more."""
    frames = [m for m in listing.media if m.angle == "frame"]

    def cut(m) -> bool:  # not cut out (yet): a backdrop compared with a backdrop says nothing about the angle
        return bool(m.processed_url and m.thumb_url and storage.owns(m.thumb_url))
    if not frames or not all(cut(m) for m in frames):
        return None
    cover = cover_photo(listing)
    if cover is None or cover.angle not in TURN_ANGLES or cover_frame(listing) is not None or not cut(cover):
        cover = None
    known = angle_frames(listing)
    sides = {side: m for side in sorted(TURN_ANGLES)
             if side not in known and (m := side_photo(listing, side)) is not None and cut(m)}
    turn, _ = one_turn(listing.media)
    if cover is None and (not sides or len(turn) < 8):
        return None
    return frames, cover, sides, turn


def media_work(state, listing: Listing) -> tuple[bool, bool]:
    """Whether cutout_listing and thumb_listing have anything to do for the listing as it is: a photo to cut out
    that has not been tried with this model, a small copy missing, or a 360° match to look for. The backfill
    runs only those, so a run over listings that are done reads no photos."""
    storage, segment = state.storage, state.segmenter
    model = cutout_model(segment)
    # A part with a photo known not to cut out has work only when it still holds cut-outs to drop.
    cut = segment is not None and any(
        (todo := [m for m in part if not m.processed_url]) and (can_cut(todo, model, storage) or len(todo) < len(part))
        for part in cutout_parts(listing.media))
    thumbs = (any(not m.thumb_url and storage.owns(m.processed_url or m.original_url) for m in listing.media)
              or listing.backdrop is None and _first_shown(storage, listing) is not None
              or _turn_match_due(storage, listing) is not None)
    return cut, thumbs


def match_turn_frames(storage: Storage, listing: Listing, made: dict[str, bytes] | None = None) -> TurnMatches | None:
    """Finds the 360° frame that shows the shoe as the cover does, and the frame of one turn that shows each side
    photographed, unless they are set for these photos and frames already (the seller's own cover frame stays).
    Compares the small copies of the cut-outs, which are cheap to read and show the shoe's outline whatever the
    room; made holds the copies this run has just made. Writes nothing: see put_turn_matches."""
    due = _turn_match_due(storage, listing)
    if due is None:
        return None
    frames, cover, sides, turn = due
    made = made or {}

    def read(url: str) -> bytes:
        try:
            return made.get(url) or storage.read(url)
        except Exception:
            log.exception("small copy %s could not be read", url)
            return b""  # skipped by the comparison

    seen = {m.thumb_url: read(m.thumb_url) for m in frames}
    best = cutout.closest_frame(read(cover.thumb_url), [seen[m.thumb_url] for m in frames]) if cover else None
    found = (cutout.side_frames({side: read(m.thumb_url) for side, m in sides.items()},
                                [seen[m.thumb_url] for m in turn]) if sides and len(turn) >= 8 else {})
    return TurnMatches(
        cover=(frames[best].original_url, cover.original_url) if best is not None else None,
        sides={side: (turn[k].original_url, sides[side].original_url) for side, k in found.items()},
        tried=bool(sides))


def put_turn_matches(listing: Listing, found: TurnMatches) -> None:
    """Writes what match_turn_frames found where it still holds for the listing as it is now (see lock_fresh):
    the frame and the photo still the listing's, and no choice of the seller's in the way."""
    now = {m.original_url for m in listing.media if m.angle == "frame"}
    current = cover_photo(listing)
    if (found.cover is not None and found.cover[0] in now and cover_frame(listing) is None
            and current is not None and current.original_url == found.cover[1]):
        listing.cover_frame, listing.cover_frame_of = found.cover
    marks = {side: {"frame": frame, "of": side_photo(listing, side).original_url}
             for side, frame in angle_frames(listing).items()}
    for side, (frame, of) in found.sides.items():
        if side not in marks and frame in now and of == getattr(side_photo(listing, side), "original_url", None):
            marks[side] = {"frame": frame, "of": of}
    # Tried and not found is kept as {}, so the backfill does not pick the listing again for its sides.
    if marks or found.sides or found.tried:
        listing.angle_frames = json.dumps(marks, sort_keys=True)


def lock_fresh(db: Session, listing: Listing, writes: list = ()) -> None:
    """Reads the listing again before writing what was worked out from it: the seller, or a job for newer photos,
    may have changed it meanwhile. On Postgres its row stays locked until the commit, so neither overwrites the
    other. The lock comes before writes (statements on its photos), as every writer takes them (the listing, then
    its photos; see own_listing), so two writers never wait on each other."""
    with db.no_autoflush:
        db.execute(select(Listing.id).where(Listing.id == listing.id).with_for_update())
    for write in writes:
        db.execute(write)
    db.flush()
    db.expire_all()
    db.refresh(listing)


def _first_shown(storage: Storage, listing: Listing):
    """The cut-out the showcase opens on, whose backdrop the listing takes."""
    shown = sorted(listing.media, key=lambda m: (m.angle != "frame", m.angle != "front", m.position))
    return next((m for m in shown if m.processed_url and storage.owns(m.processed_url)), None)


def thumb_listing(state, listing_id: int) -> int:
    """Background job: the small copies the showcase shows while scrolling, and the backdrop that suits the shoe."""
    storage = state.storage
    done = 0
    made: dict[str, bytes] = {}
    with state.sessions() as db:
        listing = db.get(Listing, listing_id)
        if listing is None:
            return 0
        writes = []
        for m in listing.media:
            source = m.processed_url or m.original_url
            if m.thumb_url or not storage.owns(source):
                continue
            try:
                small = cutout.make_thumb(storage.read(source))
                url = storage.put(small, owner_id=listing.seller_id, ext="webp")
            except Exception:
                log.exception("thumbnail failed for %s", source)
                continue
            # Written as a statement once the listing is locked, and only onto the photo as it was copied: a photo
            # deleted meanwhile matches no row, and a cut-out landing meanwhile wants a small copy of its own.
            writes.append(update(Media).where(Media.id == m.id, Media.thumb_url.is_(None),
                                              Media.processed_url.is_not_distinct_from(m.processed_url))
                          .values(thumb_url=url))
            set_committed_value(m, "thumb_url", url)  # for the 360° match below, not to be written again
            made[url] = small
            done += 1
        first = _first_shown(storage, listing)
        source = first.processed_url if first else None
        backdrop, chosen = None, True
        try:
            backdrop = cutout.backdrop_for(storage.read(source)) if source else None
        except Exception:
            log.exception("backdrop failed for listing %s", listing_id)
            chosen = False
        found = match_turn_frames(storage, listing, made)
        lock_fresh(db, listing, writes)
        # Only what still holds for the photos as they are now: a job for newer photos may have written already.
        if chosen and source == getattr(_first_shown(storage, listing), "processed_url", None):
            listing.backdrop = backdrop
        if found is not None:
            put_turn_matches(listing, found)
        db.commit()
        return done


def prepare_listing_media(state, listing_id: int) -> None:
    # Cut-outs first, so the search vector and the small copies are made from the shoe without its backdrop. Each
    # job on its own: one that fails (the storage or the database away for a moment) must not leave a new listing
    # without small copies to turn through, or out of search by photo. Nothing here tries again: what failed stays
    # missing (no cut-out, small copy or vector), which the backfill finds when it is next run (models/README.md).
    for job in (cutout_listing, thumb_listing, embed_listing):
        try:
            job(state, listing_id)
        except Exception:
            log.exception("%s failed for listing %s; scripts/cutout_backfill.py makes what is missing", job.__name__,
                          listing_id)


@router.post("/listings", status_code=201)
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
        showcase_style=body.showcase_style,
        search_text=search_text(body.title, body.brand, body.model_name, body.color, body.category),
        authenticity=Authenticity.UNVERIFIED.value,
        sizes=[ListingSize(label=s.label, insole_mm=cm_to_mm(s.insole_cm), quantity=s.quantity) for s in body.sizes],
        media=[Media(original_url=p.url, angle=p.angle, position=i) for i, p in enumerate(body.photos)],
    )
    db.add(listing)
    db.flush()
    db.add(PriceChange(listing_id=listing.id, price_tiyn=listing.price_tiyn))
    db.commit()
    if cfg.photo_work != "worker":  # else the photo worker finds the new listing (photo_work.py)
        background.add_task(prepare_listing_media, request.app.state, listing.id)
    return listing_out(db, listing, owner=True)


def own_listing(db: Session, listing_id: int, user: User, lock: bool = False) -> Listing:
    """The seller's listing; lock holds its row (on Postgres) until the commit, which a change of its photos does
    first, so it never waits on a media job that waits on it (see lock_fresh)."""
    listing = db.get(Listing, listing_id, with_for_update=lock, populate_existing=lock)
    if listing is None or listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    return listing


@router.post("/listings/{listing_id}/publish")
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


@router.patch("/listings/{listing_id}")
def edit_listing(listing_id: int, body: ListingPatch, request: Request, background: BackgroundTasks,
                 user: User = Depends(current_user), db: Session = Depends(get_db),
                 cfg: Settings = Depends(get_settings), storage: Storage = Depends(get_storage)):
    listing = own_listing(db, listing_id, user, lock=True)
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
            if item.was is not None and item.was != by_id[item.id].quantity:
                raise ApiError(409, "stock_changed")
            by_id[item.id].quantity = item.quantity
    if body.sizes is not None or body.add_sizes:
        settle_stock_status(listing)
    if changed and listing.announced_at is not None:
        recheck(db, storage, listing, changed)
        services.audit(db, user.id, "edit_listing", f"listing:{listing.id}", ",".join(sorted(changed)))
    services.tell_back_in_stock(db, listing)
    if "photos" in changed:
        # The search-by-photo vector was made from the old photos. Dropped with them, so that until the job makes a
        # new one the listing is not found by a photo it no longer has, and if the job fails the backfill sees the
        # vector missing and makes it.
        db.execute(delete(ListingEmbedding).where(ListingEmbedding.listing_id == listing.id))
    db.commit()
    if "photos" in changed and cfg.photo_work != "worker":
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
        listing.search_text = search_text(listing.title, listing.brand, listing.model_name, listing.color,
                                          listing.category)
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
            if not fresh:
                check_replacement(db, cfg, listing, body.photos)
                # Orders placed before copies were kept get one now, from the photos they were placed on.
                db.execute(update(Order).where(Order.listing_id == listing.id, Order.listing_photos.is_(None))
                           .values(listing_photos=photo_snapshot(listing)))
            replace_photos(listing, body.photos)
            changed.add("photos")
            listing.promo_state, listing.promo_url = None, None  # the promo video showed the old photos
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
    if body.cover_frame is not None:
        cover = cover_photo(listing)
        if cover is None or not any(m.angle == "frame" and m.original_url == body.cover_frame for m in listing.media):
            raise ApiError(422, "validation", "cover_frame is not one of the listing's 360° frames")
        listing.cover_frame, listing.cover_frame_of = body.cover_frame, cover.original_url
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


REQUIRED_ANGLES = ("front", "outer", "inner", "back")


def count_stills(angles: list[str]) -> int:
    return sum(a != "frame" for a in angles)


def check_replacement(db: Session, cfg: Settings, listing: Listing, photos: list[PhotoIn]) -> None:
    """A listing that was on sale may change its photos but stays as complete as it was: the main sides it showed
    are still shown, defect close-ups are not fewer, and the count publishing asks for is kept (a listing that
    already had fewer keeps at least what it had). Orders keep their own copy of what they were placed on."""
    if db.scalar(select(ListingReport.id).where(ListingReport.listing_id == listing.id,
                                                ListingReport.status == "open").limit(1)):
        raise ApiError(409, "under_review")  # staff judge the photos that were reported, not their replacement
    had = [m.angle for m in listing.media]
    new = [p.angle for p in photos]
    if (any(a in had and a not in new for a in REQUIRED_ANGLES) or new.count("defect") < had.count("defect")):
        raise ApiError(422, "photo_set_incomplete")
    if count_stills(new) < min(cfg.min_listing_photos, count_stills(had)):
        raise ApiError(422, "missing_required_photos")


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


@router.post("/listings/{listing_id}/promo", status_code=202)
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


@router.post("/me/shop-sale")
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


@router.delete("/me/shop-sale")
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


@router.post("/listings/{listing_id}/pause")
def pause_listing(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status != "published":
        raise ApiError(409, "invalid_status")
    listing.status = "paused"
    db.commit()
    return listing_out(db, listing, owner=True)


@router.post("/listings/{listing_id}/report", status_code=201)
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


@router.put("/listings/{listing_id}/sizes/{size_id}/alert")
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


@router.delete("/listings/{listing_id}/sizes/{size_id}/alert")
def cancel_stock_alert(listing_id: int, size_id: int, user: User = Depends(current_user),
                       db: Session = Depends(get_db)):
    for a in db.scalars(select(StockAlert).where(StockAlert.user_id == user.id, StockAlert.size_id == size_id,
                                                 StockAlert.listing_id == listing_id)).all():
        db.delete(a)
    db.commit()
    return {"size_id": size_id, "alert": False}


@router.get("/listings/{listing_id}")
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
            "popularity": popularity(db, listing), "colors": safe_colorways(db, listing)}


MAX_COLORWAYS = 12
NEW_CONDITIONS = {Condition.NEW_WITH_BOX.value, Condition.NEW_NO_BOX.value, Condition.UNWORN_STORED.value}


def _same(text: str | None) -> str:
    """Case, spacing and ё/е do not make another model or colour."""
    return " ".join((text or "").replace("ё", "е").replace("Ё", "Е").split()).casefold()


def _same_color(text: str | None) -> str:
    """As _same, and a colour typed in Russian or English before the picker is the same as its Kazakh name."""
    return _same(canonical_color(text or ""))


def safe_colorways(db: Session, listing: Listing) -> list[dict]:
    """The colours are an extra beside the shoe: if working them out fails, the page still opens, without them."""
    try:
        return colorways(db, listing)
    except Exception:  # noqa: BLE001 - logged; the listing itself must still load
        log.exception("colorways failed for listing %s", listing.id)
        return []


def colorways(db: Session, listing: Listing) -> list[dict]:
    """The same model from the same shop in other colours, so a buyer can switch colour beside the shoe. One entry
    per colour: for another colour the published pair of the same category closest in condition (new beside new,
    worn beside worn), then with a size in stock, then the cheapest. In colour-name order, this listing among them,
    so the swatches keep their places whichever colour is open. Empty without a model name or another colour.

    Brand and model are compared ignoring case and spacing here, not in SQL: SQLite's lower() leaves Cyrillic alone.
    Only the columns needed to choose are read, not every pair's photos and sizes."""
    model = _same(listing.model_name)
    if not model:
        return []
    brand, own, new = _same(listing.brand), _same_color(listing.color), listing.condition in NEW_CONDITIONS
    in_stock = select(ListingSize.id).where(ListingSize.listing_id == Listing.id, ListingSize.quantity > 0).exists()
    rows = db.execute(select(Listing.id, Listing.model_name, Listing.brand, Listing.color, Listing.condition,
                             Listing.price_tiyn, in_stock).where(
        Listing.seller_id == listing.seller_id, Listing.status == "published", Listing.id != listing.id,
        Listing.category == listing.category, Listing.model_name.is_not(None)))
    best: dict[str, tuple] = {}
    for id_, model_name, brand_name, color_name, condition, price, stocked in rows:
        color = _same_color(color_name)
        if _same(model_name) != model or _same(brand_name) != brand or not color or color == own:
            continue
        rank = ((condition in NEW_CONDITIONS) != new, not stocked, price, id_)
        if color not in best or rank < best[color][0]:
            best[color] = (rank, color, id_)
    if not best:
        return []
    # Past the cap, the colours most worth showing stay: the closest condition and in stock first.
    kept = sorted(best.values())[:MAX_COLORWAYS - 1]
    picked = {l.id: l for l in db.scalars(select(Listing).where(Listing.id.in_([id_ for _, _, id_ in kept])))}
    shown = sorted([(own, listing), *((color, picked[id_]) for _, color, id_ in kept)], key=lambda p: p[0])
    return [colorway_out(c, current=c.id == listing.id) for _, c in shown]


def colorway_out(listing: Listing, *, current: bool) -> dict:
    photos = [m for m in listing.media if m.angle != "frame"] or listing.media
    cover = photos[0] if photos else None
    return {"id": listing.id, "color": listing.color, "price_tiyn": listing.price_tiyn, "current": current,
            "in_stock": any(s.quantity > 0 for s in listing.sizes),
            # The small copy is made from the cut-out when there is one.
            "thumb_url": cover and (cover.thumb_url or cover.processed_url or cover.original_url),
            "cutout": bool(cover and cover.processed_url)}


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
