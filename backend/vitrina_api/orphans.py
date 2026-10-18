"""Files nobody points at any more: a photo uploaded for a listing that was never saved, a chat photo that was
never sent, the photos of a deleted listing. They cost storage and keep a person's photos around after they
are gone, so this finds them and, when asked, deletes them.

    python -m vitrina_api.orphans            # only lists what it would delete
    python -m vitrina_api.orphans --delete

A file counts as used when its key appears anywhere in any text column of any table, whatever address it is
written under: a URL column, a JSON list of photos, an address saved before the public media URL changed. Only
files older than min_age go, because an upload is stored a moment before the row that points at it, and the
references are read twice, before and after listing the files, so a row written in between still counts.
"""
from __future__ import annotations

import argparse
import logging
import re
from datetime import datetime, timedelta

from sqlalchemy import String, Text, select
from sqlalchemy.orm import Session, sessionmaker

from .models import Base
from .storage import Storage

log = logging.getLogger("vitrina.orphans")

# KEY_RE without anchors: finds keys inside URLs and JSON texts. The 32 random hex digits make a chance match
# with other text practically impossible, and a chance match only keeps a file.
KEY_IN_TEXT = re.compile(r"(?<![0-9A-Za-z])\d+/[0-9a-f]{32}\.(?:jpg|webp|png|mp4)")

MIN_AGE = timedelta(days=2)


def referenced_keys(db: Session) -> set[str]:
    found: set[str] = set()
    for table in Base.metadata.sorted_tables:
        columns = [c for c in table.columns if isinstance(c.type, (String, Text))]
        if not columns:
            continue
        for row in db.execute(select(*columns)).yield_per(1000):
            for value in row:
                if value and "/" in value:
                    found.update(KEY_IN_TEXT.findall(value))
    return found


def sweep(sessions: sessionmaker, storage: Storage, *, now: datetime, delete: bool = False,
          min_age: timedelta = MIN_AGE) -> list[str]:
    """The keys of old files no row points at; deleted too when delete is set."""
    with sessions() as db:
        before = referenced_keys(db)
    if not before:  # an empty or wrong database would make every file look unused
        raise RuntimeError("no row points at any stored file: check the database settings before sweeping")
    old = [key for key, written in storage.keys() if now - written >= min_age and key not in before]
    if not old:
        return []
    with sessions() as db:
        after = referenced_keys(db)
    orphans = [key for key in old if key not in after]
    if delete:
        for key in orphans:
            storage.delete(key)
    return orphans


def main(argv: list[str] | None = None) -> None:
    from .config import Settings
    from .deps import now_utc
    from .models import make_session_factory
    from .storage import make_storage

    parser = argparse.ArgumentParser(description="Find, and with --delete remove, stored files nothing points at.")
    parser.add_argument("--delete", action="store_true", help="delete them; without it only list them")
    args = parser.parse_args(argv)
    cfg = Settings()
    found = sweep(make_session_factory(cfg.database_url, create_schema=False), make_storage(cfg), now=now_utc(),
                  delete=args.delete)
    for key in found:
        print(key)
    print(f"{len(found)} files {'deleted' if args.delete else 'unused (run with --delete to remove them)'}")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    main()
