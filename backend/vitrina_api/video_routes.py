"""The seller's own video of a pair (the «Видео» tab): added, replaced or taken off by the seller, made smaller apart
from the request (video.py), shown to buyers once ready."""
from __future__ import annotations

import shutil
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
from .models import Listing, User
from .serializers import VIDEO_STUCK_AFTER, listing_out
from .storage import VideoUnavailable
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
        listing.video_state, listing.video_at, listing.video_seconds = "processing", started, round(seconds)
        listing.video_url = listing.video_poster_url = None
        services.audit(db, user.id, "add_video", f"listing:{listing.id}")
        db.commit()
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        queue_places.release()
        raise
    background.add_task(make_video, request.app.state, listing.id, started, str(work), True)
    return listing_out(db, listing, owner=True)


@router.delete("/listings/{listing_id}/video")
def remove_video(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = own_listing(db, listing_id, user, lock=True)
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    listing.video_state = listing.video_url = listing.video_poster_url = listing.video_seconds = None
    listing.video_at = None
    db.commit()
    return listing_out(db, listing, owner=True)


def make_video(state, listing_id: int, started: datetime, work: str, queued: bool = False) -> bool:
    """Background job: the uploaded video made smaller, stored, and shown, unless the seller sent another or took it
    off meanwhile (then this one is dropped). The upload is deleted either way. A job that waited past the time the
    seller is told it failed (VIDEO_STUCK_AFTER) stays failed, never ready later."""
    folder = Path(work)
    try:
        with state.sessions() as db:
            seller = db.scalar(select(Listing.seller_id).where(Listing.id == listing_id))
            db.rollback()
        values: dict = {"video_state": "failed"}
        if seller is not None and now_utc() - started <= VIDEO_STUCK_AFTER:
            try:
                mp4, poster = encode(folder / "in", folder)
                values = {"video_state": "ready", "video_url": state.storage.put(mp4, owner_id=seller, ext="mp4"),
                          "video_poster_url": state.storage.put(poster, owner_id=seller, ext="jpg")}
            except Exception:  # unreadable, or the server could not run ffmpeg: the seller is told to send it again
                log.exception("listing %s video not made", listing_id)
        if now_utc() - started > VIDEO_STUCK_AFTER:
            values = {"video_state": "failed"}
        with state.sessions() as db:
            done = db.execute(update(Listing).where(Listing.id == listing_id, Listing.video_at == started,
                                                    Listing.video_state == "processing").values(**values))
            db.commit()
        return done.rowcount == 1 and values["video_state"] == "ready"
    finally:
        shutil.rmtree(folder, ignore_errors=True)
        if queued:
            queue_places.release()
