"""Copies of the database kept off the server, in a bucket of their own (VITRINA_S3_BACKUP_BUCKET, on the same
endpoint and keys as the photos): a server whose disk is lost takes its local copies with it. deploy/backup.sh
makes a dump every night and hands it here; deploy/restore.sh brings one back.

    python -m vitrina_api.backup put /backups/vitrina-20261020T213000Z-3f9a0c1d.dump
    python -m vitrina_api.backup list
    python -m vitrina_api.backup get vitrina-20261020T213000Z-3f9a0c1d.dump /backups/
    python -m vitrina_api.backup prune --keep 30
    python -m vitrina_api.backup check     # the three buckets work, and only the photos one is public
    python -m vitrina_api.backup mirror /data/media /backups/files/media    # disk storage: a copy of the files

Each copy goes under db/ with its SHA-256 beside it (db/NAME.sha256), and get refuses a copy that does not match,
so a file cut short on the way is never restored. The bucket must not be public: a dump holds phone numbers and
addresses, so put refuses to go on when the copy it just wrote can be read without a key. The random part of the
name keeps a copy from being found by its time alone.

The backup bucket may have a key of its own (VITRINA_S3_BACKUP_ACCESS_KEY, VITRINA_S3_BACKUP_SECRET_KEY, kept in
deploy/backup.env, which only backup.sh and restore.sh read): then a break-in through the API, which holds the
photos' key, cannot delete the copies. A dump is read whole into memory to sign it, which is fine while it is some
hundreds of megabytes.

With VITRINA_STORAGE=disk the photos and private files are on the server's disk too: backup.sh keeps a copy of
both folders beside the dumps (mirror), and the backup bucket is optional. Without one, nothing leaves the server
until someone copies /var/backups/vitrina off it (deploy/README.md).
"""
from __future__ import annotations

import argparse
import hashlib
import re
import os
import secrets
import shutil
import sys
from pathlib import Path
from xml.etree import ElementTree

import httpx

from .config import Settings
from .storage import S3Storage

PREFIX = "db/"
# What backup.sh names a dump; nothing else is put, listed or pruned, so a stray file in the bucket is left alone.
NAME_RE = re.compile(r"vitrina-\d{8}T\d{6}Z-[0-9a-f]{8}\.dump")


def bucket(settings: Settings, client=None) -> S3Storage:
    if not settings.s3_backup_bucket:
        raise SystemExit("VITRINA_S3_BACKUP_BUCKET is not set")
    if settings.s3_backup_bucket in (settings.s3_bucket, settings.s3_private_bucket):
        raise SystemExit("VITRINA_S3_BACKUP_BUCKET must be a bucket of its own, not the photos' or the private one")
    return S3Storage(endpoint=settings.s3_endpoint, bucket=settings.s3_backup_bucket, region=settings.s3_region,
                     access_key=settings.s3_backup_access_key or settings.s3_access_key,
                     secret_key=settings.s3_backup_secret_key or settings.s3_secret_key, public_base="",
                     **({"client": client} if client is not None else {}))


def readable_without_key(s3: S3Storage, key: str) -> bool:
    """Whether anyone could read the object: a GET with no signature, as a stranger would send it."""
    return s3.client.get(f"{s3.endpoint}/{s3.bucket}/{key}").status_code < 300


def checked(name: str) -> str:
    if not NAME_RE.fullmatch(name):
        raise SystemExit(f"not a backup name: {name!r} (vitrina-YYYYMMDDTHHMMSSZ-xxxxxxxx.dump)")
    return name


def put(s3: S3Storage, path: Path) -> str:
    name, data = checked(path.name), path.read_bytes()
    if not data:
        raise SystemExit(f"{path} is empty")
    digest = hashlib.sha256(data).hexdigest()
    s3._send("PUT", PREFIX + name, data, {"content-type": "application/octet-stream"})
    s3._send("PUT", PREFIX + name + ".sha256", digest.encode(), {"content-type": "text/plain"})
    if readable_without_key(s3, PREFIX + name):
        raise SystemExit(f"the backup bucket {s3.bucket} can be read without a key: anyone could download the "
                         "database. Remove its public read access at the storage provider.")
    return digest


def names(s3: S3Storage) -> list[str]:
    """The copies in the bucket, oldest first (the names sort by time)."""
    found, token = [], None
    while True:
        query = {"list-type": "2", "prefix": PREFIX, **({"continuation-token": token} if token else {})}
        root = ElementTree.fromstring(s3._send("GET", "", query=query).content)
        for item in root.iterfind("{*}Contents"):
            name = (item.findtext("{*}Key") or "").removeprefix(PREFIX)
            if NAME_RE.fullmatch(name):
                found.append(name)
        if root.findtext("{*}IsTruncated") != "true":
            return sorted(found)
        token = root.findtext("{*}NextContinuationToken")


def get(s3: S3Storage, name: str, dest: Path) -> Path:
    data = s3._send("GET", PREFIX + checked(name)).content
    expected = s3._send("GET", PREFIX + name + ".sha256").content.decode().strip()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit(f"{name}: the copy does not match its SHA-256, not restoring it")
    target = dest / name if dest.is_dir() else dest
    target.write_bytes(data)
    target.with_name(target.name + ".sha256").write_text(f"{expected}  {target.name}\n")  # as sha256sum writes it
    return target


def prune(s3: S3Storage, keep: int) -> list[str]:
    """Deletes all but the keep newest copies."""
    if keep < 1:
        raise SystemExit("--keep must be at least 1")
    gone = names(s3)[:-keep]
    for name in gone:
        s3._send("DELETE", PREFIX + name)
        s3._send("DELETE", PREFIX + name + ".sha256")
    return gone


def mirror(src: Path, dst: Path, *, keep_extra: bool = False) -> tuple[int, int]:
    """Makes dst hold what src holds: new and changed files copied (through a temporary name, so a cut-off run
    never leaves half a file), files src no longer has removed unless keep_extra. Returns (copied, removed)."""
    if not src.is_dir():
        raise SystemExit(f"{src} is not a folder")
    files = {p.relative_to(src) for p in src.rglob("*") if p.is_file() and not p.is_symlink()}
    if not files and not keep_extra and dst.is_dir() and any(p.is_file() for p in dst.rglob("*")):
        # An empty source is far likelier a missing volume than every file deleted: the copy is not wiped.
        raise SystemExit(f"{src} is empty but its copy {dst} is not: not removing the copy")
    dst.mkdir(parents=True, exist_ok=True)  # even for an empty folder: restore.sh --files expects both copies
    copied = removed = 0
    for rel in sorted(files):
        a, b = src / rel, dst / rel
        sa = a.stat()
        if b.is_file() and (b.stat().st_size, int(b.stat().st_mtime)) == (sa.st_size, int(sa.st_mtime)):
            continue
        b.parent.mkdir(parents=True, exist_ok=True)
        tmp = b.with_name(b.name + ".mirror-part")
        shutil.copy2(a, tmp)
        os.replace(tmp, b)
        copied += 1
    if not keep_extra and dst.is_dir():
        for b in sorted(dst.rglob("*"), reverse=True):  # files before their folders
            rel = b.relative_to(dst)
            if b.is_file() and rel not in files:  # with a .mirror-part left by a run cut off
                b.unlink()
                removed += 1
            elif b.is_dir() and not any(b.iterdir()):
                b.rmdir()
    return copied, removed


def check_disk(settings: Settings) -> list[str]:
    """Disk storage: each folder takes a file, gives it back and lets it go (the volumes are mounted and writable).
    Whether Caddy serves the photos at VITRINA_PUBLIC_MEDIA_URL is checked from outside (setup.sh, smoke.sh)."""
    from .storage import make_private_storage, make_storage
    problems = []
    for label, store in (("VITRINA_MEDIA_DIR", make_storage(settings)),
                         ("VITRINA_PRIVATE_MEDIA_DIR", make_private_storage(settings))):
        try:
            url = store.put(b"vitrina storage check", owner_id=0, ext="jpg")
            if store.read(url) != b"vitrina storage check":
                problems.append(f"{label}: the file read back is not the one written")
            store.delete(url.removeprefix(store.public_base + "/"))
        except OSError as e:
            problems.append(f"{label}: {e}")
    return problems


def check(settings: Settings, client=None) -> list[str]:
    """Writes a small file to each bucket, reads it back the way the app does and deletes it: the photos bucket must
    answer at VITRINA_PUBLIC_MEDIA_URL without a key, the other two must refuse a stranger. Returns what is wrong.
    With disk storage: the two folders, and the backup bucket if there is one."""
    from .storage import make_private_storage, make_storage
    if settings.storage == "disk":
        stores = [("VITRINA_S3_BACKUP_BUCKET", bucket(settings), False)] if settings.s3_backup_bucket else []
        problems = check_disk(settings)
    elif not (settings.s3_bucket and settings.s3_private_bucket):
        raise SystemExit("set VITRINA_S3_BUCKET and VITRINA_S3_PRIVATE_BUCKET: this checks the live storage")
    else:
        stores = [("VITRINA_S3_BUCKET", make_storage(settings), True),
                  ("VITRINA_S3_PRIVATE_BUCKET", make_private_storage(settings), False),
                  ("VITRINA_S3_BACKUP_BUCKET", bucket(settings), False)]
        problems = []
    probe = b"vitrina storage check"
    for label, store, public in stores:
        if client is not None:
            store.client = client
        key = f"check/{secrets.token_hex(8)}.txt"
        try:
            store._send("PUT", key, probe, {"content-type": "text/plain"})
            if store._send("GET", key).content != probe:
                problems.append(f"{label}: the file read back is not the one written")
            if public:
                url = f"{settings.public_media_url.rstrip('/')}/{key}"
                if store.client.get(url).content != probe:
                    problems.append(f"{label}: photos are not readable at VITRINA_PUBLIC_MEDIA_URL ({url})")
            elif readable_without_key(store, key):
                problems.append(f"{label}: can be read without a key; it must not be public")
            store._send("DELETE", key)
        except (RuntimeError, httpx.HTTPError) as e:
            problems.append(f"{label}: {e} (check the endpoint, the keys and that the bucket exists)")
    return problems


def main(argv: list[str] | None = None, client=None) -> None:
    parser = argparse.ArgumentParser(prog="python -m vitrina_api.backup", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("put").add_argument("file", type=Path)
    sub.add_parser("list")
    g = sub.add_parser("get")
    g.add_argument("name")
    g.add_argument("dest", type=Path)
    sub.add_parser("prune").add_argument("--keep", type=int, default=30)
    sub.add_parser("check")
    m = sub.add_parser("mirror")
    m.add_argument("src", type=Path)
    m.add_argument("dst", type=Path)
    m.add_argument("--keep-extra", action="store_true", help="never remove a file from dst")
    args = parser.parse_args(argv)
    if args.cmd == "check":
        settings = Settings()
        problems = check(settings, client)
        print("\n".join(problems) or ("storage ok: both folders writable" + (", backup bucket closed"
                                       if settings.s3_backup_bucket else ", no backup bucket")
                                       if settings.storage == "disk" else
                                       "storage ok: photos public, private and backup buckets closed"))
        raise SystemExit(1 if problems else 0)
    if args.cmd == "mirror":
        copied, removed = mirror(args.src, args.dst, keep_extra=args.keep_extra)
        print(f"{args.src} -> {args.dst}: {copied} copied, {removed} removed")
        return
    s3 = bucket(Settings(), client)
    if args.cmd == "put":
        print(f"{args.file.name} {put(s3, args.file)}")
    elif args.cmd == "list":
        print("\n".join(names(s3)))
    elif args.cmd == "get":
        print(get(s3, args.name, args.dest))
    else:
        for name in prune(s3, args.keep):
            print(f"deleted {name}")


if __name__ == "__main__":
    sys.exit(main())
