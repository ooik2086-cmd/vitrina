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

from vitrina_api import cutout, visual  # noqa: E402
from vitrina_api.config import Settings  # noqa: E402
from vitrina_api.models import make_session_factory  # noqa: E402
from vitrina_api.photo_work import due_work, work_listing  # noqa: E402
from vitrina_api.storage import make_storage  # noqa: E402


# Failures in a row taken as the database or the storage being down rather than one listing's photos.
STOP_AFTER = 5


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
    due = due_work(state)
    ids = list(due)
    failed: list[int] = []
    done = in_a_row = 0
    for lid in ids:
        results, broke, photo_errors = work_listing(state, lid, due[lid][0])
        if broke or photo_errors:
            failed.append(lid)
            print(f"listing {lid}: failed{' in ' + ', '.join(broke) if broke else ''}, see the error above", flush=True)
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
        said = {"cutout": f"{results.get('cutout')} photos cut out", "thumbs": f"{results.get('thumbs')} small copies",
                "vector": f"search vector {'ok' if results.get('vector') else 'not made'}"}
        print(f"listing {lid}: " + ", ".join(said[name] for name in results), flush=True)
    print(f"{done} of {len(ids)} listings done"
          + (f"; failed: {', '.join(map(str, failed))}" if failed else ""), flush=True)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    main()
