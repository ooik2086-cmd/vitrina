"""Time-based work: orders the buyer never confirmed complete on their own, and the review reminder.

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
        completed = services.run_auto_complete(db, now=now, window=settings.confirm_window, rule=settings.commission)
    with sessions() as db:
        reminded = services.run_review_reminders(db, now=now)
    return {"completed": completed, "review_reminders": reminded}


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
