"""The heavy photo work of a listing: cut-outs, small scrolling copies, the backdrop, the 360° matches and the
search-by-photo vector. Cutting out one listing's ~40 photos takes about two minutes of every core, so in a live
deployment it runs here, in its own process, and the API answers buyers meanwhile:

    VITRINA_PHOTO_WORK=worker   (for the API: it then leaves photo work to the worker)
    python -m vitrina_api.photo_worker

What is due is read from the database each time (a photo not cut out, a small copy or a vector missing), so nothing
is lost when either process restarts, and new or edited listings go first. scripts/cutout_backfill.py does the same
work once over the whole catalogue.
"""
from __future__ import annotations

import logging
import time

from sqlalchemy import select
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import noload, selectinload

from . import visual
from .listing_routes import cutout_listing, embed_listing, embedded_photo, media_work, thumb_listing
from .models import Listing, ListingEmbedding, Media
from .serializers import photos_version

log = logging.getLogger(__name__)  # under the root logger, where work_listing counts the jobs' errors too


class _Errors(logging.Handler):
    """Counts the errors the jobs log and carry on from, such as one photo that cannot be cut out."""

    def __init__(self) -> None:
        super().__init__(logging.ERROR)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        self.count += 1


def due_work(state, chunk: int = 500) -> dict[int, tuple[list, str]]:
    """The jobs each listing still needs and the photo set they are for, in id order. Only listings with something
    to do, so a pass over listings that are done reads no photos: a label left as taken, or a photo the model found
    no shoe in, is not cut out again. Worked out a chunk of listings at a time, so a big catalogue is never all
    loaded."""
    uncut = select(Media.listing_id).where(Media.processed_url.is_(None) | Media.thumb_url.is_(None))
    current = select(ListingEmbedding.listing_id).where(ListingEmbedding.model == visual.MODEL_NAME)
    turning = select(Media.listing_id).where(Media.angle == "frame")
    sided = select(Media.listing_id).where(Media.angle.in_(["outer", "front", "inner", "back"]))
    unmatched = Listing.id.in_(turning) & (Listing.cover_frame.is_(None)
                                           | Listing.angle_frames.is_(None) & Listing.id.in_(sided))
    wanted = Listing.id.in_(uncut) | Listing.backdrop.is_(None) | unmatched
    if state.embedder is not None:
        wanted |= Listing.id.not_in(current)
    due: dict[int, tuple[list, str]] = {}
    with state.sessions() as db:
        ids = db.scalars(select(Listing.id).where(wanted).order_by(Listing.id)).all()
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
                    due[listing.id] = (jobs, photos_version(listing))
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


class Worker:
    def __init__(self, state, clock=time.monotonic):
        self.state, self.clock = state, clock
        self.waits: dict[tuple[int, str], tuple[float, int]] = {}  # (listing, photo set) -> (not before, tries)

    def next_listing(self) -> tuple[int, list, str] | None:
        """The newest listing due and not waiting: a new or edited listing goes before an old one being caught
        up on."""
        due = due_work(self.state)
        now = self.clock()
        self.waits = {key: wait for key, wait in self.waits.items() if due.get(key[0], (None, None))[1] == key[1]}
        for lid in sorted(due, reverse=True):
            jobs, version = due[lid]
            if self.waits.get((lid, version), (0.0, 0))[0] <= now:
                return lid, jobs, version
        return None

    def step(self) -> int | None:
        """Works one listing; returns its id, or None when nothing is due."""
        found = self.next_listing()
        if found is None:
            return None
        lid, jobs, version = found
        started = self.clock()
        results, broke, photo_errors = work_listing(self.state, lid, jobs)
        tries = self.waits.get((lid, version), (0.0, 0))[1] + 1
        # Counted as a try whatever happened: when it is due again on the next look, it did not get done.
        self.waits[(lid, version)] = (self.clock() + min(LONGEST_WAIT_S, FIRST_WAIT_S * 2 ** (tries - 1)), tries)
        log.info("listing %s: %s in %.0fs%s", lid, ", ".join(f"{name} {n}" for name, n in results.items()),
                 self.clock() - started, f"; failed: {', '.join(broke)}" if broke else
                 ("; an error on a photo, see above" if photo_errors else ""))
        return lid

    def run(self, interval_s: float, should_stop=lambda: False) -> None:
        while not should_stop():
            try:
                worked = self.step()
            except Exception:  # the database away for a moment: look again later
                log.exception("photo work pass failed")
                worked = None
            if worked is None:
                time.sleep(interval_s)
