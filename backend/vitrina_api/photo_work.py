"""The heavy photo work of a listing: cut-outs, small scrolling copies, the backdrop, the 360° matches and the
search-by-photo vector. Cutting out one listing's ~40 photos takes about two minutes of every core, so in a live
deployment it runs here, in its own process, and the API answers buyers meanwhile:

    VITRINA_PHOTO_WORK=worker   (for the API: it then leaves photo work to the worker)
    python -m vitrina_api.photo_worker

What is due is read from the database each time (a photo not cut out, a small copy or a vector missing), so nothing
is lost when either process restarts. Photos sellers gave in the last day go first, in the order they came; older
work after them. Run one worker: two would cut out the same listing side by side. scripts/cutout_backfill.py does
the same work once over the whole catalogue.
"""
from __future__ import annotations

import hashlib
import logging
import threading
import time
from datetime import datetime, timedelta
from typing import NamedTuple

from sqlalchemy import func, select
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import noload, selectinload

from . import visual
from .deps import now_utc
from .listing_routes import (CUTOUT_ANGLES, cutout_listing, cutout_model, embed_listing, embedded_photo, media_work,
                             thumb_listing)
from .models import Listing, ListingEmbedding, Media
from .services import aware

log = logging.getLogger(__name__)  # under the root logger, where work_listing counts the jobs' errors too


class _Errors(logging.Handler):
    """Counts the errors the jobs log and carry on from, such as one photo that cannot be cut out."""

    def __init__(self) -> None:
        super().__init__(logging.ERROR)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        self.count += 1


class Due(NamedTuple):
    jobs: list
    photos: str  # the photo set the jobs are for: a new set is new work, whatever happened to the old one
    changed_at: datetime | None  # when the seller gave these photos


def photo_set(listing: Listing) -> str:
    """Names the photos and their sides, in order. Unlike photos_version not the text, so a seller fixing a typo
    does not make a listing the worker is waiting on look like new work."""
    shown = sorted(listing.media, key=lambda m: (m.position, m.id))
    return hashlib.sha256("\n".join(f"{m.original_url} {m.angle}" for m in shown).encode()).hexdigest()[:16]


def due_work(state, chunk: int = 500, known: dict | None = None) -> dict[int, Due]:
    """The jobs each listing still needs, in id order. Only listings with something to do, so a pass over listings
    that are done reads no photos: a label or a photo the model found no shoe in is never cut out, and is not
    looked at again. Worked out a chunk of listings at a time, so a big catalogue is never all loaded.

    The database picks the candidates; only they are read with their photos. A few are candidates for good with
    nothing to do (a turn whose cover cannot be matched, say). Pass known, kept between calls, and such a listing
    is read again only once something about its photos changes."""
    work = Media.thumb_url.is_(None)
    if state.segmenter is not None:
        model = cutout_model(state.segmenter)
        work |= (Media.processed_url.is_(None) & Media.angle.in_(sorted(CUTOUT_ANGLES))
                 & (Media.no_cutout.is_(None) | (Media.no_cutout != model)))
    uncut = select(Media.listing_id).where(work)
    has_cutout = select(Media.listing_id).where(Media.processed_url.is_not(None))
    current = select(ListingEmbedding.listing_id).where(ListingEmbedding.model == visual.MODEL_NAME)
    turning = select(Media.listing_id).where(Media.angle == "frame")
    sided = select(Media.listing_id).where(Media.angle.in_(["outer", "front", "inner", "back"]))
    unmatched = Listing.id.in_(turning) & (Listing.cover_frame.is_(None)
                                           | Listing.angle_frames.is_(None) & Listing.id.in_(sided))
    wanted = Listing.id.in_(uncut) | Listing.backdrop.is_(None) & Listing.id.in_(has_cutout) | unmatched
    if state.embedder is not None:
        wanted |= Listing.id.not_in(current)
    due: dict[int, Due] = {}
    with state.sessions() as db:
        ids = db.scalars(select(Listing.id).where(wanted).order_by(Listing.id)).all()
        if known is not None:
            # What a listing's work depends on, cheaply: its photo rows and what the jobs write.
            marks = {row[0]: tuple(row[1:]) for row in db.execute(
                select(Listing.id, Listing.backdrop, Listing.cover_frame, Listing.angle_frames,
                       Listing.id.in_(current), func.count(Media.id), func.max(Media.id),
                       func.count(Media.processed_url), func.count(Media.thumb_url))
                .outerjoin(Media, Media.listing_id == Listing.id).where(wanted)
                .group_by(Listing.id, Listing.backdrop, Listing.cover_frame, Listing.angle_frames))}
            for lid in [lid for lid in known if lid not in marks]:
                del known[lid]
            ids = [lid for lid in ids if known.get(lid) != marks.get(lid)]
    for at in range(0, len(ids), chunk):
        with state.sessions() as db:
            part = ids[at:at + chunk]
            fresh = set(db.scalars(current.where(ListingEmbedding.listing_id.in_(part))))
            for listing in db.scalars(select(Listing).where(Listing.id.in_(part)).order_by(Listing.id)
                                      .options(selectinload(Listing.media), noload(Listing.sizes))):
                cut, thumbs = media_work(state, listing)
                vector = (state.embedder is not None and listing.id not in fresh
                          and embedded_photo(state.storage, listing) is not None)
                jobs = [job for job, needed in ((cutout_listing, cut), (thumb_listing, thumbs),
                                                (embed_listing, vector)) if needed]
                if jobs:
                    due[listing.id] = Due(jobs, photo_set(listing), listing.photos_changed_at)
                    if known is not None:
                        known.pop(listing.id, None)
                elif known is not None:
                    known[listing.id] = marks.get(listing.id)
    return due


def work_listing(state, listing_id: int, jobs: list) -> tuple[dict, list[str], bool]:
    """Runs the listing's jobs, each on its own as after an upload: small copies and the search vector are still
    made when the cut-outs fail, and the other way round. Returns what each job did, the jobs that broke, and
    whether an error was logged on a photo (a file gone from the storage, say). What each did is keyed cutout,
    thumbs and vector."""
    errors = _Errors()
    logging.getLogger().addHandler(errors)
    results, broke, jobs = {}, [], list(jobs)
    try:
        for name, job in (("cutout", cutout_listing), ("thumbs", thumb_listing), ("vector", embed_listing)):
            if job not in jobs:
                continue
            try:
                results[name] = job(state, listing_id)
            except Exception as e:
                log.exception("listing %s: %s failed", listing_id, job.__name__)
                broke.append(job.__name__)
                if isinstance(e, DBAPIError):  # the database is away: the other jobs need it too
                    break
            if job is cutout_listing:
                # Cut-outs kept or dropped, even by a run that failed half way, want small copies of what is shown
                # now, the backdrop and a search vector made again; each job skips what is done.
                jobs += [thumb_listing] + ([embed_listing] if state.embedder is not None else [])
    finally:
        logging.getLogger().removeHandler(errors)
    return results, broke, errors.count > 0


# A listing still due after its work (it failed, or something about it cannot be done) waits before the next try:
# a minute, doubling up to an hour. Keyed by its photo set, so a seller who changes the photos is served at once.
FIRST_WAIT_S, LONGEST_WAIT_S = 60.0, 3600.0
# Photos given this recently are a seller waiting: served first, in the order they came. Older work (a catalogue
# caught up on after a new model, listings from before photos_changed_at was kept) comes after, newest first.
FRESH = timedelta(days=1)


class Worker:
    def __init__(self, state, clock=time.monotonic, wall=now_utc):
        self.state, self.clock, self.wall = state, clock, wall
        self.waits: dict[tuple[int, str], tuple[float, int]] = {}  # (listing, photo set) -> (not before, tries)
        self.known: dict = {}  # listings read and found with nothing to do, for due_work
        self.stopping = threading.Event()

    def next_listing(self) -> tuple[int, Due] | None:
        """The listing to work next and not waiting: fresh photos first, oldest first, then the rest."""
        due = due_work(self.state, known=self.known)
        now, since = self.clock(), self.wall() - FRESH
        self.waits = {key: wait for key, wait in self.waits.items() if key[0] in due and due[key[0]].photos == key[1]}

        def order(lid):
            changed = due[lid].changed_at and aware(due[lid].changed_at)
            return (0, changed.timestamp(), lid) if changed is not None and changed >= since else (1, 0.0, -lid)
        for lid in sorted(due, key=order):
            if self.waits.get((lid, due[lid].photos), (0.0, 0))[0] <= now:
                return lid, due[lid]
        return None

    def step(self) -> int | None:
        """Works one listing; returns its id, or None when nothing is due."""
        found = self.next_listing()
        if found is None:
            return None
        lid, todo = found
        started = self.clock()
        results, broke, photo_errors = work_listing(self.state, lid, todo.jobs)
        tries = self.waits.get((lid, todo.photos), (0.0, 0))[1] + 1
        # Counted as a try whatever happened: when it is due again on the next look, it did not get done.
        self.waits[(lid, todo.photos)] = (self.clock() + min(LONGEST_WAIT_S, FIRST_WAIT_S * 2 ** (tries - 1)), tries)
        log.info("listing %s: %s in %.0fs%s", lid, ", ".join(f"{name} {n}" for name, n in results.items()),
                 self.clock() - started, f"; failed: {', '.join(broke)}" if broke else
                 ("; an error on a photo, see above" if photo_errors else ""))
        return lid

    def run(self, interval_s: float, alive=lambda: None) -> None:
        """Works until stop(); alive() is called after every listing and every look that found nothing, for a
        health check to see the worker is not stuck."""
        while not self.stopping.is_set():
            try:
                worked = self.step()
            except Exception:  # the database away for a moment: look again later
                log.exception("photo work pass failed")
                worked = None
            alive()
            if worked is None:
                self.stopping.wait(interval_s)

    def stop(self) -> None:
        """Stops after the listing it is on."""
        self.stopping.set()
