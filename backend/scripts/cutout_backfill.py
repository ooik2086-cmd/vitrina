"""Prepare photos of existing listings: transparent-background versions, small scrolling copies, the backdrop,
the 360° frame that matches the cover and search-by-photo vectors.

    VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx VITRINA_SEARCH_MODEL=models/mobilenetv2-12.onnx \
        python3 scripts/cutout_backfill.py

Uses the same database and storage settings as the API. Safe to run again: done photos are skipped.

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

from vitrina_api import cutout, visual  # noqa: E402
from vitrina_api.listing_routes import cutout_listing, embed_listing, thumb_listing  # noqa: E402
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
    with state.sessions() as db:
        uncut = select(Media.listing_id).where(Media.processed_url.is_(None) | Media.thumb_url.is_(None))
        current = select(ListingEmbedding.listing_id).where(ListingEmbedding.model == visual.MODEL_NAME)
        turning = select(Media.listing_id).where(Media.angle == "frame")
        sided = select(Media.listing_id).where(Media.angle.in_(["outer", "front", "inner", "back"]))
        unmatched = Listing.id.in_(turning) & (Listing.cover_frame.is_(None)
                                               | Listing.angle_frames.is_(None) & Listing.id.in_(sided))
        ids = db.scalars(select(Listing.id).where(Listing.id.in_(uncut) | Listing.id.not_in(current) | unmatched)
                         .order_by(Listing.id)).all()
    errors = _Errors()
    logging.getLogger().addHandler(errors)
    failed: list[int] = []
    done = in_a_row = 0
    try:
        for lid in ids:
            logged = errors.count
            # Each job on its own, as after an upload: small copies and the search vector are still made when the
            # cut-outs fail, and the other way round. Any failure counts the listing as failed.
            results = []
            for job in (cutout_listing, thumb_listing, embed_listing):
                try:
                    results.append(job(state, lid))
                except Exception:
                    logging.getLogger(__name__).exception("listing %s: %s failed", lid, job.__name__)
                    results.append(None)
            cut, thumbs, embedded = results
            if None in results or errors.count > logged:
                failed.append(lid)
                in_a_row += 1
                print(f"listing {lid}: failed, see the error above", flush=True)
                if in_a_row >= STOP_AFTER:
                    print(f"stopped: {STOP_AFTER} listings in a row failed; is the database or the storage down?",
                          flush=True)
                    break
                continue
            done += 1
            in_a_row = 0
            print(f"listing {lid}: {cut} photos cut out, {thumbs} small copies, "
                  f"search vector {'ok' if embedded else 'skipped'}", flush=True)
    finally:
        logging.getLogger().removeHandler(errors)
    print(f"{done} of {len(ids)} listings done"
          + (f"; failed: {', '.join(map(str, failed))}" if failed else ""), flush=True)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    main()
