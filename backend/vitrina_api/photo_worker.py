"""Runs the photo work in its own process: `python -m vitrina_api.photo_worker` (see photo_work.py).

Uses the same database, storage and model settings as the API. Runs at a lower priority than the API when both
share a machine, so a seller's upload does not slow down buyers browsing.
"""
from __future__ import annotations

import logging
import os
import signal
import sys
from types import SimpleNamespace

from . import cutout, visual
from .config import Settings
from .models import make_session_factory
from .photo_work import Worker
from .storage import make_storage

log = logging.getLogger("vitrina_api.photo_worker")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Settings()
    try:
        os.nice(cfg.photo_worker_nice)
    except OSError:
        log.warning("could not lower the priority")
    segmenter, embedder = cutout.load_segmenter(cfg.cutout_model), visual.load_embedder(cfg.search_model)
    if segmenter is None or embedder is None:
        # Said once and loudly: without the models only the small copies and the 360° matches are made.
        log.error("a model did not load (VITRINA_CUTOUT_MODEL, VITRINA_SEARCH_MODEL): no %s",
                  " and no ".join(name for name, m in (("cut-outs", segmenter), ("search vectors", embedder))
                                  if m is None))
    state = SimpleNamespace(segmenter=segmenter, embedder=embedder, storage=make_storage(cfg),
                            sessions=make_session_factory(cfg.database_url, create_schema=False))
    stop = []
    # Stops after the listing it is on. Killed half way instead, that listing is simply still due when it starts.
    signal.signal(signal.SIGTERM, lambda *_: stop.append(True))
    log.info("photo worker started")
    Worker(state).run(cfg.photo_worker_interval_s, should_stop=lambda: bool(stop))
    log.info("photo worker stopped")


if __name__ == "__main__":
    sys.exit(main())
