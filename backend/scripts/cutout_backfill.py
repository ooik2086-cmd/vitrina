"""Prepare photos of existing listings: transparent-background versions, small scrolling copies, the backdrop,
the 360° frame that matches the cover and search-by-photo vectors.

    VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx VITRINA_SEARCH_MODEL=models/mobilenetv2-12.onnx \
        python3 scripts/cutout_backfill.py

Uses the same database and storage settings as the API. Safe to run again, and meant to run on a schedule:
only what is missing is done, and listings with nothing missing are not even read from the storage.

A listing whose work fails, or logs an error on one of its photos, is counted as failed and the rest carry on;
five failures in a row stop the run, as that is the database or the storage being down, not one listing. The
last line sums it up, and the exit status says it to whoever runs it: 0 all done, 1 some listings failed, 2 a
model did not load (pass --without-models to make only the small copies and the 360° matches).
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select  # noqa: E402
from sqlalchemy.exc import DBAPIError  # noqa: E402
from sqlalchemy.orm import noload, selectinload  # noqa: E402

from vitrina_api import cutout, visual  # noqa: E402
from vitrina_api.listing_routes import (cutout_listing, embed_listing, embedded_photo, media_work,  # noqa: E402
                                        thumb_listing)
from vitrina_api.config import Settings  # noqa: E402
from vitrina_api.models import Listing, ListingEmbedding, Media, make_session_factory  # noqa: E402
from vitrina_api.storage import make_storage  # noqa: E402


# Failures in a row taken as the database or the storage being down rather than one listing's photos.
STOP_AFTER = 5


class _Errors(logging.Handler):
    """Counts the errors the jobs log and carry on from, such as one photo that cannot be cut out."""

    def __init__(self) -> None:
        super().__init__(logging.ERROR)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        self.count += 1


def _due(state, chunk: int = 500) -> dict[int, list]:
    """The jobs each listing still needs, in id order. Only listings with something to do, so a nightly run over
    listings that are done reads no photos: a label left as taken, or a photo the model found no shoe in, is not
    cut out again every night. Worked out a chunk of listings at a time, so a big catalogue is never all loaded."""
    uncut = select(Media.listing_id).where(Media.processed_url.is_(None) | Media.thumb_url.is_(None))
    current = select(ListingEmbedding.listing_id).where(ListingEmbedding.model == visual.MODEL_NAME)
    turning = select(Media.listing_id).where(Media.angle == "frame")
    sided = select(Media.listing_id).where(Media.angle.in_(["outer", "front", "inner", "back"]))
    unmatched = Listing.id.in_(turning) & (Listing.cover_frame.is_(None)
                                           | Listing.angle_frames.is_(None) & Listing.id.in_(sided))
    wanted = Listing.id.in_(uncut) | Listing.backdrop.is_(None) | unmatched
    if state.embedder is not None:
        wanted |= Listing.id.not_in(current)
    due: dict[int, list] = {}
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
                    due[listing.id] = jobs
    return due


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Prepare photos of existing listings.")
    parser.add_argument("--without-models", action="store_true",
                        help="make the small copies and the 360° matches even if a model is missing")
    args = parser.parse_args(argv)
    cfg = Settings()
    segmenter, embedder = cutout.load_segmenter(cfg.cutout_model), visual.load_embedder(cfg.search_model)
    if (segmenter is None or embedder is None) and not args.without_models:
        print("a model did not load: set VITRINA_CUTOUT_MODEL and VITRINA_SEARCH_MODEL, or pass --without-models",
              file=sys.stderr, flush=True)
        sys.exit(2)
    state = SimpleNamespace(segmenter=segmenter, embedder=embedder,
                            storage=make_storage(cfg),
                            sessions=make_session_factory(cfg.database_url, create_schema=False))
    due = _due(state)
    ids = list(due)
    errors = _Errors()
    logging.getLogger().addHandler(errors)
    failed: list[int] = []
    done = in_a_row = 0
    try:
        for lid in ids:
            logged = errors.count
            # Each job on its own, as after an upload: small copies and the search vector are still made when the
            # cut-outs fail, and the other way round. Any failure counts the listing as failed.
            results, broke = {}, []
            jobs = due[lid]
            for job in (cutout_listing, thumb_listing, embed_listing):
                if job not in jobs:
                    continue
                try:
                    results[job] = job(state, lid)
                except Exception as e:
                    logging.getLogger(__name__).exception("listing %s: %s failed", lid, job.__name__)
                    broke.append(job.__name__)
                    if isinstance(e, DBAPIError):  # the database is away: the other jobs need it too
                        break
                if job is cutout_listing:
                    # Cut-outs kept or dropped, even by a run that failed half way, want small copies of what is
                    # shown now, the backdrop and a search vector made again; each job skips what is done.
                    jobs += [thumb_listing] + ([embed_listing] if state.embedder is not None else [])
            if broke or errors.count > logged:
                failed.append(lid)
                print(f"listing {lid}: failed{' in ' + ', '.join(broke) if broke else ''}, see the error above",
                      flush=True)
                # Only jobs that broke count towards stopping: an error logged on one photo (a file gone from the
                # storage, say) is that listing's own, and fails it again every night.
                in_a_row = in_a_row + 1 if broke else 0
                if in_a_row >= STOP_AFTER:
                    print(f"stopped: {STOP_AFTER} listings in a row failed; is the database or the storage down?",
                          flush=True)
                    break
                continue
            done += 1
            in_a_row = 0
            said = {cutout_listing: f"{results.get(cutout_listing)} photos cut out",
                    thumb_listing: f"{results.get(thumb_listing)} small copies",
                    embed_listing: f"search vector {'ok' if results.get(embed_listing) else 'not made'}"}
            print(f"listing {lid}: " + ", ".join(said[job] for job in results), flush=True)
    finally:
        logging.getLogger().removeHandler(errors)
    print(f"{done} of {len(ids)} listings done"
          + (f"; failed: {', '.join(map(str, failed))}" if failed else ""), flush=True)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    main()
