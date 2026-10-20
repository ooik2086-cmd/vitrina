"""Copies of the database kept off the server, in a bucket of their own (VITRINA_S3_BACKUP_BUCKET, on the same
endpoint and keys as the photos): a server whose disk is lost takes its local copies with it. deploy/backup.sh
makes a dump every night and hands it here; deploy/restore.sh brings one back.

    python -m vitrina_api.backup put /backups/vitrina-20261020T020000Z.dump
    python -m vitrina_api.backup list
    python -m vitrina_api.backup get vitrina-20261020T020000Z.dump /backups/
    python -m vitrina_api.backup prune --keep 30

Each copy goes under db/ with its SHA-256 beside it (db/NAME.sha256), and get refuses a copy that does not match,
so a file cut short on the way is never restored. The bucket must not be public: a dump holds phone numbers and
addresses. A dump is read whole into memory to sign it, which is fine while it is some hundreds of megabytes.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path
from xml.etree import ElementTree

from .config import Settings
from .storage import S3Storage

PREFIX = "db/"
# What backup.sh names a dump; nothing else is put, listed or pruned, so a stray file in the bucket is left alone.
NAME_RE = re.compile(r"vitrina-\d{8}T\d{6}Z\.dump")


def bucket(settings: Settings, client=None) -> S3Storage:
    if not settings.s3_backup_bucket:
        raise SystemExit("VITRINA_S3_BACKUP_BUCKET is not set")
    if settings.s3_backup_bucket in (settings.s3_bucket, settings.s3_private_bucket):
        raise SystemExit("VITRINA_S3_BACKUP_BUCKET must be a bucket of its own, not the photos' or the private one")
    return S3Storage(endpoint=settings.s3_endpoint, bucket=settings.s3_backup_bucket, region=settings.s3_region,
                     access_key=settings.s3_access_key, secret_key=settings.s3_secret_key, public_base="",
                     **({"client": client} if client is not None else {}))


def checked(name: str) -> str:
    if not NAME_RE.fullmatch(name):
        raise SystemExit(f"not a backup name: {name!r} (vitrina-YYYYMMDDTHHMMSSZ.dump)")
    return name


def put(s3: S3Storage, path: Path) -> str:
    name, data = checked(path.name), path.read_bytes()
    if not data:
        raise SystemExit(f"{path} is empty")
    digest = hashlib.sha256(data).hexdigest()
    s3._send("PUT", PREFIX + name, data, {"content-type": "application/octet-stream"})
    s3._send("PUT", PREFIX + name + ".sha256", digest.encode(), {"content-type": "text/plain"})
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


def main(argv: list[str] | None = None, client=None) -> None:
    parser = argparse.ArgumentParser(prog="python -m vitrina_api.backup", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("put").add_argument("file", type=Path)
    sub.add_parser("list")
    g = sub.add_parser("get")
    g.add_argument("name")
    g.add_argument("dest", type=Path)
    sub.add_parser("prune").add_argument("--keep", type=int, default=30)
    args = parser.parse_args(argv)
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
