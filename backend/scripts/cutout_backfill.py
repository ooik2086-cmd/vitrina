"""Prepare photos of existing listings: transparent-background versions, small scrolling copies, the backdrop
and search-by-photo vectors.

    VITRINA_CUTOUT_MODEL=models/isnet-general-use.onnx VITRINA_SEARCH_MODEL=models/mobilenetv2-12.onnx \
        python3 scripts/cutout_backfill.py

Uses the same database and storage settings as the API. Safe to run again: done photos are skipped.
"""
from __future__ import annotations

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


def main() -> None:
    cfg = Settings()
    segmenter, embedder = cutout.load_segmenter(cfg.cutout_model), visual.load_embedder(cfg.search_model)
    state = SimpleNamespace(segmenter=segmenter, embedder=embedder,
                            storage=make_storage(cfg),
                            sessions=make_session_factory(cfg.database_url, create_schema=False))
    with state.sessions() as db:
        uncut = select(Media.listing_id).where(Media.processed_url.is_(None) | Media.thumb_url.is_(None))
        current = select(ListingEmbedding.listing_id).where(ListingEmbedding.model == visual.MODEL_NAME)
        ids = db.scalars(select(Listing.id).where(Listing.id.in_(uncut) | Listing.id.not_in(current))
                         .order_by(Listing.id)).all()
    for lid in ids:
        cut = cutout_listing(state, lid)
        thumbs = thumb_listing(state, lid)
        print(f"listing {lid}: {cut} photos cut out, {thumbs} small copies, search vector {'ok' if embed_listing(state, lid) else 'skipped'}",
              flush=True)


if __name__ == "__main__":
    main()
