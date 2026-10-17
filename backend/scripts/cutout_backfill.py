"""Add transparent-background versions to listings that don't have them yet.

    VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx python3 scripts/cutout_backfill.py

Uses the same database and storage settings as the API. Safe to run again: done photos are skipped.
"""
from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select  # noqa: E402

from vitrina_api import cutout  # noqa: E402
from vitrina_api.app import cutout_listing  # noqa: E402
from vitrina_api.config import Settings  # noqa: E402
from vitrina_api.models import Listing, Media, make_session_factory  # noqa: E402
from vitrina_api.storage import LocalStorage  # noqa: E402


def main() -> None:
    cfg = Settings()
    segmenter = cutout.load_segmenter(cfg.cutout_model)
    if segmenter is None:
        raise SystemExit("set VITRINA_CUTOUT_MODEL to a model file (see models/README.md)")
    state = SimpleNamespace(segmenter=segmenter, storage=LocalStorage(cfg.media_dir, cfg.public_media_url),
                            sessions=make_session_factory(cfg.database_url, create_schema=False))
    with state.sessions() as db:
        ids = db.scalars(select(Listing.id).where(Listing.id.in_(
            select(Media.listing_id).where(Media.processed_url.is_(None)))).order_by(Listing.id)).all()
    for lid in ids:
        print(f"listing {lid}: {cutout_listing(state, lid)} photos cut out", flush=True)


if __name__ == "__main__":
    main()
