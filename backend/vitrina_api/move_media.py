"""Gives the stored photos their new address after the site moves: a new domain (VITRINA_STORAGE=disk), or from the
server's disk into the S3 buckets (VITRINA_STORAGE=s3). Every row keeps each photo's full address, so the addresses
in the database are rewritten, and a move to S3 copies the files first.

    python -m vitrina_api.move_media https://OLD-DOMAIN/media              # shows what it would do, changes nothing
    python -m vitrina_api.move_media https://OLD-DOMAIN/media --copy-only  # s3: copies the files, changes no row
    python -m vitrina_api.move_media https://OLD-DOMAIN/media --yes        # does it

Run it with the settings of the new place (VITRINA_PUBLIC_MEDIA_URL; with s3 also VITRINA_STORAGE and the S3 lines)
while the API, the photo worker and the jobs are stopped (deploy/README.md): nothing then writes an old address
meanwhile or waits on the rows being rewritten. With s3 the files still on disk (VITRINA_MEDIA_DIR,
VITRINA_PRIVATE_MEDIA_DIR) are copied into the buckets under the same keys, private files first; a file already there
is skipped, so the long copy can run beforehand with --copy-only while the site still works. Addresses are rewritten
only when every file they name is in place and the photos bucket answers a stranger, all in one transaction, so a
failed copy or a row whose new text would not fit changes no row. The files on disk are left as they are. Running it
again does only what is left.

Only an address followed by a key the storage wrote (storage.KEY_BODY) is rewritten, so other text that happens to
start with the old address stays as it is. Private files are written as "private:/<key>", never as an address: they
are copied, never rewritten. The app writes JSON with plain slashes, so escaped or percent-encoded forms are not
looked for. When nothing is found under the old address but photos sit under another one, it stops and names that
one: a mistyped address must not look like a finished move.
"""
from __future__ import annotations

import argparse
import logging
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from sqlalchemy import String, Text, and_, or_, select, text, update
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

from .models import Base
from .storage import KEY_BODY, KEY_RE, LocalStorage, Storage

log = logging.getLogger("vitrina.move_media")

PROGRESS_EVERY = 200  # files between progress lines while copying
# Any web address right before a stored-file key: where photos are, when not where the operator said.
SOME_BASE = re.compile(r"(https?://[^\s\"'<>\\]+?)/(?=" + KEY_BODY + ")")


class MoveRefused(RuntimeError):
    pass


@dataclass
class Copy:
    copied: list[str] = field(default_factory=list)
    present: int = 0  # already in the destination
    failed: list[str] = field(default_factory=list)


@dataclass
class Rewrite:
    rows: int = 0
    addresses: int = 0
    keys: set[str] = field(default_factory=set)  # the stored files the old addresses name
    # "table.column (id)" whose new text would be longer than the column allows: nothing is written while any is.
    too_long: list[str] = field(default_factory=list)


def base_of(url: str) -> str:
    """A media address as the storage writes it: no trailing slash. Anything but http(s)://host/... is refused."""
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https") or not parts.netloc or parts.query or parts.fragment:
        raise MoveRefused(f"{url!r} is not an address like https://OLD-DOMAIN/media")
    return url.strip().rstrip("/")


def disk_keys(root: Path) -> list[str]:
    """The files under a media folder in new_key's shape, the same ones LocalStorage.keys lists. A linked folder or
    file is skipped: it may lead outside the volume, for example to private files that must not reach a public
    bucket."""
    if not root.is_dir():
        return []
    return sorted(key for path in root.glob("*/*")
                  if KEY_RE.fullmatch(key := path.relative_to(root).as_posix())
                  and not path.parent.is_symlink() and path.is_file() and not path.is_symlink())


def copy_files(root: Path, dest: Storage, *, apply: bool, label: str = "files") -> Copy:
    """Every file under root that dest lacks, written there under the same key. A dry run only lists them."""
    result = Copy()
    there = {key for key, _ in dest.keys()}
    for key in disk_keys(root):
        if key in there:
            result.present += 1
            continue
        if not apply:
            result.copied.append(key)
            continue
        try:
            dest.put_at(key, (root / key).read_bytes())
        except Exception:  # one failed file must not stop the rest; it is reported and nothing is rewritten
            log.exception("could not copy %s", key)
            result.failed.append(key)
            continue
        result.copied.append(key)
        if len(result.copied) % PROGRESS_EVERY == 0:
            print(f"{label}: {len(result.copied)} copied so far", flush=True)
    return result


def text_columns(table):
    return [c for c in table.columns if isinstance(c.type, (String, Text))]


def rewrite(db: Session, old: str, new: str, *, apply: bool) -> Rewrite:
    """Every stored-file address under old, in any text column of any table (URL columns and JSON lists alike),
    moved to new. Writes nothing when a new text would not fit its column. The caller commits."""
    result = Rewrite()
    found = re.compile(re.escape(old + "/") + f"(?={KEY_BODY})")
    named = re.compile(re.escape(old + "/") + f"({KEY_BODY})")
    changes = []
    for table in Base.metadata.sorted_tables:
        columns = text_columns(table)
        keys = list(table.primary_key.columns)
        if not columns or not keys:
            continue
        query = select(*keys, *columns).where(or_(*(c.contains(old + "/", autoescape=True) for c in columns)))
        for row in db.execute(query):
            ident, values = row[:len(keys)], row[len(keys):]
            before, after = {}, {}
            for column, value in zip(columns, values):
                if not value:
                    continue
                moved, n = found.subn(new + "/", value)
                if not n:
                    continue
                result.addresses += n
                result.keys.update(m.group(1) for m in named.finditer(value))
                before[column.name], after[column.name] = value, moved
                if column.type.length and len(moved) > column.type.length:
                    result.too_long.append(f"{table.name}.{column.name} ({', '.join(map(str, ident))})")
            if after:
                result.rows += 1
                changes.append((table, dict(zip((k.name for k in keys), ident)), before, after))
    if not apply or result.too_long:
        return result
    for table, ident, before, after in changes:
        # Only while the row still says what was read: a row changed meanwhile is not overwritten.
        where = [table.c[name] == value for name, value in ident.items()]
        where += [table.c[name] == value for name, value in before.items()]
        done = db.execute(update(table).where(and_(*where)).values(after))
        if done.rowcount != 1:
            raise MoveRefused(f"{table.name} ({', '.join(map(str, ident.values()))}) changed while being moved: "
                              "nothing was rewritten; stop the API (deploy/README.md) and run it again")
    return result


def other_bases(db: Session, skip: set[str]) -> dict[str, int]:
    """The web addresses stored files are named under, apart from skip, with how many times each appears."""
    seen: dict[str, int] = {}
    for table in Base.metadata.sorted_tables:
        columns = text_columns(table)
        if not columns:
            continue
        query = select(*columns).where(or_(*(c.contains("://", autoescape=True) for c in columns)))
        for row in db.execute(query.execution_options(yield_per=1000)):
            for value in row:
                for m in SOME_BASE.finditer(value or ""):
                    if m.group(1) not in skip:
                        seen[m.group(1)] = seen.get(m.group(1), 0) + 1
    return seen


def publicly_readable(dest, base: str, key: str) -> bool:
    """Whether a phone could load the file at its new address: a plain GET, no signature."""
    try:
        return dest.client.get(f"{base}/{key}").status_code < 300
    except Exception:
        return False


def main(argv: list[str] | None = None) -> int:
    from sqlalchemy.engine import make_url

    from . import services
    from .config import Settings
    from .models import make_session_factory
    from .storage import make_private_storage, make_storage

    parser = argparse.ArgumentParser(description="Move stored photos to the address VITRINA_PUBLIC_MEDIA_URL names.")
    parser.add_argument("old", help="the photos' old address, e.g. https://old-domain.kz/media")
    parser.add_argument("--yes", action="store_true", help="do it; without it only show what would change")
    parser.add_argument("--copy-only", action="store_true", help="with s3: copy the files, rewrite no address")
    args = parser.parse_args(argv)
    cfg = Settings()
    try:
        old, new = base_of(args.old), base_of(cfg.public_media_url)
    except MoveRefused as e:
        print(f"stopped: {e}", file=sys.stderr)
        return 2
    print(f"database: {make_url(cfg.database_url).render_as_string(hide_password=True)}")
    print(f"photos: {old} -> {new}")
    storage, private = make_storage(cfg), make_private_storage(cfg)
    to_bucket = not isinstance(storage, LocalStorage)
    if to_bucket and old == new:
        print("stopped: VITRINA_PUBLIC_MEDIA_URL is still the old address; with VITRINA_STORAGE=s3 it must be the "
              "photos bucket's public address (deploy/README.md)", file=sys.stderr)
        return 2
    def where(s):
        return getattr(s, "endpoint", None), getattr(s, "bucket", None)
    if to_bucket and where(private) == where(storage):
        print("stopped: VITRINA_S3_PRIVATE_BUCKET must not be the photos bucket: receipts would be public",
              file=sys.stderr)
        return 2
    if args.copy_only and not to_bucket:
        print("stopped: --copy-only is for a move to S3 (VITRINA_STORAGE=s3)", file=sys.stderr)
        return 2
    copy = args.yes or args.copy_only
    # Moving to the buckets: the files still on the server's disk go first, under the same keys. Private ones
    # (receipts, dispute evidence) first: until they are copied, a support check of a dispute cannot open them.
    for root, dest, label in ((cfg.private_media_dir, private, "private files"), (cfg.media_dir, storage, "photos")):
        if isinstance(dest, LocalStorage):
            continue  # on disk already: the address changes, the file stays where it is
        copied = copy_files(Path(root), dest, apply=copy, label=label)
        print(f"{label}: {len(copied.copied)} {'copied' if copy else 'to copy'} from {root} to "
              f"{getattr(dest, 'bucket', '')}, {copied.present} already there"
              + (f", {len(copied.failed)} failed" if copied.failed else ""), flush=True)
        for key in copied.failed:
            print(f"failed: {key}", file=sys.stderr)
        if copied.failed:
            print("stopped: no address was rewritten while a file is missing; run it again", file=sys.stderr)
            return 1
    if args.copy_only:
        print("files copied; no address changed")
        return 0
    if old == new:
        print("the old address is the current one: no address to rewrite (if you changed .env, the command did "
              "not get the new settings)")
        return 0
    sessions = make_session_factory(cfg.database_url, create_schema=False)
    try:
        with sessions() as db:
            if db.bind.dialect.name == "postgresql":  # one pass over every table may run past the API's 30 s limit
                db.execute(text("SET LOCAL statement_timeout = '15min'"))
            return _rewrite(db, old, new, args.yes, storage if to_bucket else None, services)
    except DBAPIError as e:
        print(f"stopped, nothing was rewritten: the database refused ({type(e.orig).__name__}); stop the API, the "
              "photo worker and the jobs (deploy/README.md) and run it again", file=sys.stderr)
        return 2
    finally:
        sessions.kw["bind"].dispose()


def _rewrite(db: Session, old: str, new: str, apply: bool, bucket, services) -> int:
    """bucket: the photos bucket the files were just copied into, or None when they stay on disk."""
    try:
        result = rewrite(db, old, new, apply=apply)
    except MoveRefused as e:
        db.rollback()
        print(f"stopped: {e}", file=sys.stderr)
        return 2
    if result.addresses == 0:
        db.rollback()
        others = other_bases(db, {new})
        if others:
            for base, n in sorted(others.items(), key=lambda kv: -kv[1]):
                print(f"photos found under: {base} ({n} addresses)", file=sys.stderr)
            print(f"stopped: no photo address starts with {old}; run it with the address above", file=sys.stderr)
            return 2
        print(f"nothing left to move: every photo address already starts with {new}")
        return 0
    for place in result.too_long:
        print(f"too long with the new address: {place}", file=sys.stderr)
    if result.too_long:
        db.rollback()
        print("stopped: nothing was rewritten; use a shorter VITRINA_PUBLIC_MEDIA_URL", file=sys.stderr)
        return 2
    if bucket is not None and apply:
        # Every file on the disk was just copied, so a file named here and missing there was already lost before
        # the move: said, not a reason to keep every other photo on the old address.
        there = {key for key, _ in bucket.keys()}
        lost = sorted(result.keys - there)
        for key in lost[:20]:
            print(f"missing before the move (on neither the disk nor the bucket): {key}", file=sys.stderr)
        if lost:
            print(f"{len(lost)} files the database names were already missing", file=sys.stderr)
        readable = sorted(result.keys & there)
        if readable and not publicly_readable(bucket, new, readable[0]):
            db.rollback()
            print(f"stopped: {new}/{readable[0]} does not open without a key: check VITRINA_PUBLIC_MEDIA_URL and "
                  "that the photos bucket allows public reading; nothing was rewritten", file=sys.stderr)
            return 2
    print(f"{result.addresses} addresses in {result.rows} rows {'rewritten' if apply else 'to rewrite'}")
    if not apply:
        db.rollback()
        print("nothing changed; run with --yes to do it")
        return 0
    services.audit(db, None, "media.move", new[-80:],
                   f"from {old[-200:]}: {result.addresses} addresses in {result.rows} rows")
    db.commit()
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    sys.exit(main())
