"""The seller's own video of a pair (the «Видео» tab): added, replaced or taken off by the seller, made smaller apart
from the request (video.py), shown to buyers once ready."""
from __future__ import annotations

import shutil
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, File, Request, UploadFile
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from . import services
from .api_common import log
from .deps import current_user, get_db, now_utc
from .errors import ApiError
from .listing_routes import own_listing
from .models import Listing, Order, User
from .serializers import VIDEO_STUCK_AFTER, listing_out
from .storage import VideoUnavailable, key_of
from .video import VIDEO_UPLOAD_BYTES, encode, probe_seconds, queue_places

router = APIRouter(prefix="/api/v1")

# Each try reads up to 200 MB and may take two cores for a minute or two: a seller filming again and again is fine,
# a loop is not.
VIDEO_TRIES_PER_HOUR = 10
CHUNK = 1 << 20


def receive(file: UploadFile, dest: Path) -> None:
    """The upload onto disk, never all in memory; 413 past VIDEO_UPLOAD_BYTES."""
    size = 0
    with dest.open("wb") as out:
        while chunk := file.file.read(CHUNK):
            size += len(chunk)
            if size > VIDEO_UPLOAD_BYTES:
                raise ApiError(413, "video_too_large")
            out.write(chunk)


@router.post("/listings/{listing_id}/video", status_code=202)
def add_video(listing_id: int, request: Request, background: BackgroundTasks, file: UploadFile = File(...),
              user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    if not request.app.state.video_limiter.allow(str(user.id), time.monotonic()):
        raise ApiError(429, "rate_limited")
    # A place in the short line for the encoder, held until the video is made: when it is full, try again later.
    if not queue_places.acquire(blocking=False):
        raise ApiError(503, "video_unavailable")
    # Read and checked with no transaction open: a minute of video on a weak line takes a while to arrive.
    db.rollback()
    work = Path(tempfile.mkdtemp(prefix="vitrina-video-"))
    try:
        try:
            receive(file, work / "in")
            seconds = probe_seconds(work / "in")
        except VideoUnavailable as exc:
            log.warning("listing %s video not checked: %s", listing_id, exc)
            raise ApiError(503, "video_unavailable") from None
        listing = own_listing(db, listing_id, user, lock=True)
        started = now_utc()
        # Buyers see the old video, if any, no more: the seller replaced it, and the new one shows once made.
        old = [listing.video_url, listing.video_poster_url]
        listing.video_state, listing.video_at, listing.video_seconds = "processing", started, round(seconds)
        listing.video_url = listing.video_poster_url = None
        services.audit(db, user.id, "add_video", f"listing:{listing.id}")
        db.commit()
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        queue_places.release()
        raise
    # The job first: it gives back the encoder's place, which nothing after it may hold up.
    background.add_task(make_video, request.app.state, listing.id, started, str(work), True)
    background.add_task(free_files, request.app.state, listing.id, old)
    return listing_out(db, listing, owner=True)


@router.delete("/listings/{listing_id}/video")
def remove_video(listing_id: int, request: Request, background: BackgroundTasks, user: User = Depends(current_user),
                 db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user, lock=True)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    background.add_task(free_files, request.app.state, listing.id, [listing.video_url, listing.video_poster_url])
    listing.video_state = listing.video_url = listing.video_poster_url = listing.video_seconds = None
    listing.video_at = None
    db.commit()
    return listing_out(db, listing, owner=True)


def free_files(state, listing_id: int, urls: list[str | None]) -> None:
    """Background, after the change is saved: a video's files once nothing shows them any more. The listing no
    longer does (replaced, taken off, or a job's late result dropped); an order's copy of the listing keeps the video
    its buyer watched, and then so does the storage. Only the listing's seller's own files. Never raises: a file that
    fails to go costs a little storage and is left for the orphans sweep, and nothing after this may be skipped."""
    try:
        storage = state.storage
        with state.sessions() as db:
            listing = db.get(Listing, listing_id)
            if listing is None:
                return
            shown, seller = {listing.video_url, listing.video_poster_url}, listing.seller_id
            keys = [key_of(storage.public_base, u, seller) for u in urls if u and u not in shown]
            ordered = {k for k in keys if k and db.scalar(
                select(Order.id).where(Order.listing_id == listing_id, Order.listing_details.contains(k)).limit(1))}
            db.rollback()
        for key in keys:
            if key and key not in ordered:
                storage.delete(key)
    except Exception:  # noqa: BLE001 - see above
        log.warning("listing %s old video files not deleted", listing_id, exc_info=True)


def make_video(state, listing_id: int, started: datetime, work: str, queued: bool = False) -> bool:
    """Background job: the uploaded video made smaller, stored, and shown, unless the seller sent another or took it
    off meanwhile (then this one is dropped). The upload is deleted either way. A job that waited past the time the
    seller is told it failed (VIDEO_STUCK_AFTER) stays failed, never ready later."""
    folder = Path(work)
    stored: list[str] = []  # what this job wrote, freed unless the listing ends up showing it
    try:
        with state.sessions() as db:
            seller = db.scalar(select(Listing.seller_id).where(Listing.id == listing_id))
            db.rollback()
        values: dict = {"video_state": "failed"}
        if seller is not None and now_utc() - started <= VIDEO_STUCK_AFTER:
            try:
                mp4, poster = encode(folder / "in", folder)
                stored.append(state.storage.put(mp4, owner_id=seller, ext="mp4"))
                stored.append(state.storage.put(poster, owner_id=seller, ext="jpg"))
                values = {"video_state": "ready", "video_url": stored[0], "video_poster_url": stored[1]}
            except Exception:  # unreadable, or the server could not run ffmpeg: the seller is told to send it again
                log.exception("listing %s video not made", listing_id)
        if now_utc() - started > VIDEO_STUCK_AFTER:
            values = {"video_state": "failed"}
        with state.sessions() as db:
            done = db.execute(update(Listing).where(Listing.id == listing_id, Listing.video_at == started,
                                                    Listing.video_state == "processing").values(**values))
            db.commit()
        shown = done.rowcount == 1 and values["video_state"] == "ready"
        if not shown:
            stored, dropped = [], stored  # sent again or taken off meanwhile, too late, or half stored: shown nowhere
            free_files(state, listing_id, dropped)
        return shown
    finally:
        if stored and sys.exc_info()[0] is not None:  # the job broke after storing: those files are shown nowhere
            free_files(state, listing_id, stored)
        shutil.rmtree(folder, ignore_errors=True)
        if queued:
            queue_places.release()
