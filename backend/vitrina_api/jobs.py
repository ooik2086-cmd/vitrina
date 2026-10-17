"""Time-based work: unpaid orders let go of their pair, a paid order the seller ignores is refunded, orders the
buyer never confirmed complete on their own, the review reminder, and a tip on listings that do not sell.

Run it from cron with `python -m vitrina_api.jobs` (one pass, then exit), or let the API process do it by
setting VITRINA_JOBS_INTERVAL to a number of seconds. With several API processes, use cron instead so the
jobs do not run side by side.
"""
from __future__ import annotations

import asyncio
import logging

from sqlalchemy.orm import sessionmaker

from . import services
from .config import Settings
from .models import make_session_factory
from .deps import now_utc

log = logging.getLogger("vitrina.jobs")


def run_once(sessions: sessionmaker, settings: Settings) -> dict[str, list[int]]:
    now = now_utc()
    with sessions() as db:
        expired = services.run_expire_orders(db, now=now)
    with sessions() as db:
        completed = services.run_auto_complete(db, now=now, window=settings.confirm_window, rule=settings.commission)
    with sessions() as db:
        reminded = services.run_review_reminders(db, now=now)
    with sessions() as db:
        tips = services.run_stale_listing_tips(db, now=now)
    with sessions() as db:
        purged = services.run_purge(db, now=now)
    return {**expired, "completed": completed, "review_reminders": reminded, "listing_tips": tips, "purged": purged}


async def loop(sessions: sessionmaker, settings: Settings, interval_s: int) -> None:
    while True:
        try:
            done = await asyncio.to_thread(run_once, sessions, settings)
            if any(done.values()):
                log.info("jobs: %s", done)
        except Exception:  # one bad pass must not stop the next one
            log.exception("jobs pass failed")
        await asyncio.sleep(interval_s)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    cfg = Settings()
    print(run_once(make_session_factory(cfg.database_url, create_schema=cfg.auto_create_schema), cfg))
