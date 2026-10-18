"""Files nobody points at any more: a photo uploaded for a listing that was never saved, a chat photo that was
never sent, a photo the seller replaced. They cost storage, so this finds them and, when asked, deletes them.
It does not remove what a deleted account left behind: those rows are kept (orders, disputes), so their photos
are still in use.

    python -m vitrina_api.orphans            # only lists what it would delete
    python -m vitrina_api.orphans --delete

A file counts as used when its key appears anywhere in any text column of any table, whatever address it is
written under: a URL column, a JSON list of photos, an address saved before the public media URL changed. Only
files older than MIN_AGE go, because the app uploads a photo as soon as it is picked and the row that points at
it comes when the seller saves, maybe days later. References are read again just before deleting, so a row
written meanwhile still counts. If more than MAX_SHARE of the old files look unused, the database is probably
not the one this storage belongs to, and nothing is deleted without --force.
"""
from __future__ import annotations

import argparse
import logging
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from urllib.parse import unquote

from sqlalchemy import JSON, String, Text, cast, select
from sqlalchemy.orm import Session, sessionmaker

from .models import Base
from .storage import KEY_BODY, Storage

log = logging.getLogger("vitrina.orphans")

# The same shape the storage writes (storage.KEY_BODY), found inside URLs and JSON texts. The 32 random hex digits
# make a chance match with other text practically impossible, and a chance match only keeps a file.
KEY_IN_TEXT = re.compile(r"(?<![0-9A-Za-z])" + KEY_BODY)

MIN_AGE = timedelta(days=7)
MAX_SHARE = 0.2


class SweepRefused(RuntimeError):
    pass


@dataclass
class Sweep:
    stored: int = 0  # files older than MIN_AGE
    referenced: int = 0  # keys found in the database
    orphans: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)


def keys_in(value: str) -> list[str]:
    # Also an address written percent-encoded or with JSON's escaped slash.
    text = unquote(value.replace("\\/", "/"))
    return [m.group(0) for m in KEY_IN_TEXT.finditer(text)]


def referenced_keys(db: Session, only: set[str] | None = None) -> set[str]:
    """Every stored-file key any row mentions; with only, just which of those keys are mentioned."""
    found: set[str] = set()
    for table in Base.metadata.sorted_tables:
        columns = [c if isinstance(c.type, (String, Text)) else cast(c, Text)
                   for c in table.columns if isinstance(c.type, (String, Text, JSON))]
        if not columns:
            continue
        # Streamed in batches (a server-side cursor on PostgreSQL), so a big table is never held in memory at once.
        for row in db.execute(select(*columns).execution_options(yield_per=1000)):
            for value in row:
                if value:
                    found.update(k for k in keys_in(value) if only is None or k in only)
    return found


def sweep(sessions: sessionmaker, storage: Storage, *, now: datetime, delete: bool = False, force: bool = False,
          min_age: timedelta = MIN_AGE, max_share: float = MAX_SHARE) -> Sweep:
    result = Sweep()
    with sessions() as db:
        before = referenced_keys(db)
    result.referenced = len(before)
    if not before:  # an empty or wrong database would make every file look unused
        raise SweepRefused("no row points at any stored file: check the database settings")
    old = []
    for key, written in storage.keys():
        if now - written >= min_age:
            result.stored += 1
            if key not in before:
                old.append(key)
    del before
    if not old:
        return result
    with sessions() as db:
        later = referenced_keys(db, only=set(old))
    result.orphans = [key for key in old if key not in later]
    if delete and not force and len(result.orphans) > max_share * result.stored:
        raise SweepRefused(f"{len(result.orphans)} of {result.stored} old files look unused, more than "
                           f"{max_share:.0%}: is this the database this storage belongs to? Use --force if it is")
    if delete:
        for key in result.orphans:
            try:
                storage.delete(key)
            except Exception:  # one failed file must not stop the rest; it is reported and tried again next time
                log.exception("could not delete %s", key)
                result.failed.append(key)
                continue
            log.info("deleted %s", key)
            result.deleted.append(key)
    return result


def where(storage: Storage) -> str:
    return getattr(storage, "bucket", None) or str(getattr(storage, "root", storage.public_base))


def main(argv: list[str] | None = None) -> int:
    from sqlalchemy.engine import make_url

    from . import services
    from .config import Settings
    from .deps import now_utc
    from .models import make_session_factory
    from .storage import make_private_storage, make_storage

    parser = argparse.ArgumentParser(description="Find, and with --delete remove, stored files nothing points at.")
    parser.add_argument("--delete", action="store_true", help="delete them; without it only list them")
    parser.add_argument("--force", action="store_true", help=f"delete even when more than {MAX_SHARE:.0%} look unused")
    args = parser.parse_args(argv)
    cfg = Settings()
    sessions = make_session_factory(cfg.database_url, create_schema=False)
    print(f"database: {make_url(cfg.database_url).render_as_string(hide_password=True)}")
    code = 0
    for storage in (make_storage(cfg), make_private_storage(cfg)):  # photos, then receipts and dispute evidence
        print(f"storage: {where(storage)}")
        try:
            result = sweep(sessions, storage, now=now_utc(), delete=args.delete, force=args.force)
        except SweepRefused as e:
            print(f"stopped, nothing deleted here: {e}", file=sys.stderr)
            code = max(code, 2)
            continue
        for key in result.orphans:
            print(key)
        print(f"{result.stored} files older than {MIN_AGE.days} days, {result.referenced} keys in the database, "
              f"{len(result.orphans)} unused")
        if not args.delete:
            print("nothing deleted; run with --delete to remove them")
            continue
        with sessions() as db:
            services.audit(db, None, "orphans.delete", where(storage)[-80:],
                           f"deleted {len(result.deleted)}, failed {len(result.failed)}")
            db.commit()
        print(f"deleted {len(result.deleted)}, failed {len(result.failed)}")
        for key in result.failed:
            print(f"failed: {key}", file=sys.stderr)
        if result.failed:
            code = max(code, 1)
    return code

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    sys.exit(main())
