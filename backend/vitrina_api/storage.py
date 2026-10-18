"""Photo storage. Uploads are decoded, upright-rotated and re-encoded so no EXIF (GPS, device) survives."""
from __future__ import annotations

import hashlib
import hmac
import io
import logging
import re
import resource
import secrets
import shutil
import subprocess
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, urlsplit

import httpx

from PIL import Image, ImageOps, UnidentifiedImageError

from .errors import ApiError

log = logging.getLogger("vitrina.storage")

MAX_UPLOAD_BYTES = 12 * 1024 * 1024
MAX_SIDE_PX = 2000
MIN_SIDE_PX = 400
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
# Decompression-bomb guard: refuse anything that would decode beyond ~50 MP.
Image.MAX_IMAGE_PIXELS = 50_000_000

# ISO base media files all start with an ftyp box; the brand says whether it is a video or a HEIC/AVIF still.
VIDEO_BRANDS = {b"isom", b"iso2", b"iso4", b"iso5", b"iso6", b"mp41", b"mp42", b"avc1", b"qt  ", b"M4V ", b"3gp4",
                b"3gp5", b"3gp6", b"3g2a", b"dash", b"MSNV"}
VIDEO_COPY_CAP = MAX_UPLOAD_BYTES + (1 << 20)  # a clean copy is about the input's size; leave room for the index
VIDEO_SECONDS = 20  # a 12 MB stream copy takes well under a second; anything slower is not a normal phone clip
_video_slots = threading.BoundedSemaphore(2)  # ffmpeg runs per API process at once


def is_video(data: bytes) -> bool:
    return data[4:8] == b"ftyp" and data[8:12] in VIDEO_BRANDS


class VideoUnavailable(Exception):
    """ffmpeg is missing, busy or too slow: a server problem, not the file's fault."""


def _limit_ffmpeg() -> None:
    # In the child, before exec: no file over the upload cap, a few seconds of CPU, bounded memory.
    resource.setrlimit(resource.RLIMIT_FSIZE, (VIDEO_COPY_CAP, VIDEO_COPY_CAP))
    resource.setrlimit(resource.RLIMIT_CPU, (VIDEO_SECONDS, VIDEO_SECONDS))
    resource.setrlimit(resource.RLIMIT_AS, (1 << 30, 1 << 30))


def clean_video(data: bytes) -> bytes:
    """The same MP4 with its metadata (phone model, place, time) dropped; the picture is copied, not re-encoded.

    Raises ApiError 415 for a file ffmpeg cannot read as an MP4/MOV, or whose copy would grow past the upload cap
    (a crafted sample table can repeat the same bytes many times), and VideoUnavailable when the server cannot run it.
    """
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise VideoUnavailable("ffmpeg not found")
    if not _video_slots.acquire(blocking=False):
        raise VideoUnavailable("busy")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            src, out = Path(tmp) / "in.mp4", Path(tmp) / "out.mp4"
            src.write_bytes(data)
            try:
                run = subprocess.run(
                    [ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-protocol_whitelist", "file", "-f", "mov",
                     "-i", str(src), "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1", "-map_metadata:s",
                     "-1", "-map_chapters", "-1", "-c", "copy", "-fs", str(VIDEO_COPY_CAP), "-fflags", "+bitexact",
                     "-movflags", "+faststart", str(out)],
                    capture_output=True, timeout=VIDEO_SECONDS, preexec_fn=_limit_ffmpeg)
            except subprocess.TimeoutExpired as exc:
                raise VideoUnavailable("timeout") from exc
            except OSError as exc:
                raise VideoUnavailable(str(exc)) from exc
            size = out.stat().st_size if out.exists() else 0
            # -fs stops at the cap, so a copy that reached it was cut short: refuse it rather than store half.
            if run.returncode != 0 or size == 0 or size >= VIDEO_COPY_CAP or size > 2 * len(data):
                log.info("video refused: exit %s, %s of %s bytes, %s", run.returncode, size, len(data),
                         run.stderr.decode(errors="replace")[-300:].strip())
                raise ApiError(415, "unsupported_video", "the video could not be read")
            return out.read_bytes()
    finally:
        _video_slots.release()


def normalize_image(data: bytes) -> bytes:
    """Return a clean JPEG: orientation applied, metadata dropped, long side capped.

    Only geometry and encoding change; colours and content are left as photographed.
    """
    try:
        img = Image.open(io.BytesIO(data))
        if img.format not in ALLOWED_FORMATS:
            raise ApiError(415, "unsupported_media", f"format {img.format}")
        img = ImageOps.exif_transpose(img)
        img.load()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as exc:
        raise ApiError(415, "unsupported_media", str(exc)) from exc
    if min(img.size) < MIN_SIDE_PX:
        raise ApiError(422, "image_too_small", f"min side {MIN_SIDE_PX}px")
    if img.mode not in ("RGB", "L"):
        # Flatten transparency onto white, as a studio backdrop would be.
        base = Image.new("RGB", img.size, (255, 255, 255))
        base.paste(img, mask=img.convert("RGBA").getchannel("A"))
        img = base
    img.thumbnail((MAX_SIDE_PX, MAX_SIDE_PX), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=88, optimize=True, progressive=True)
    return out.getvalue()


class Storage(Protocol):
    """Where photos and videos live. A stored file is addressed by its public URL, which starts with public_base."""
    public_base: str

    def put(self, data: bytes, *, owner_id: int, ext: str = "jpg") -> str: ...

    def owns(self, url: str, owner_id: int | None = None) -> bool: ...

    def read(self, url: str) -> bytes: ...


def new_key(owner_id: int, ext: str) -> str:
    return f"{owner_id}/{secrets.token_hex(16)}.{ext}"


# The only shape new_key produces. Anything else (quotes, "</script>", "?", "#", "..") was not written by us.
KEY_RE = re.compile(r"(\d+)/[0-9a-f]{32}\.(?:jpg|webp|png|mp4)")


def key_of(public_base: str, url: str, owner_id: int | None = None) -> str | None:
    """The storage key of a URL we wrote, or None. With owner_id, only that user's own files count."""
    if not isinstance(url, str) or not url.startswith(public_base + "/"):
        return None
    key = url[len(public_base) + 1:]
    m = KEY_RE.fullmatch(key)
    if m is None or (owner_id is not None and int(m.group(1)) != owner_id):
        return None
    return key


CONTENT_TYPES = {"jpg": "image/jpeg", "webp": "image/webp", "png": "image/png", "mp4": "video/mp4"}


class LocalStorage:
    """Development storage on disk. Production uses S3Storage with a bucket hosted in Kazakhstan."""

    def __init__(self, root: str, public_base: str):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.public_base = public_base.rstrip("/")

    def put(self, data: bytes, *, owner_id: int, ext: str = "jpg") -> str:
        name = new_key(owner_id, ext)
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return f"{self.public_base}/{name}"

    def owns(self, url: str, owner_id: int | None = None) -> bool:
        return key_of(self.public_base, url, owner_id) is not None

    def read(self, url: str) -> bytes:
        key = key_of(self.public_base, url)
        if key is None:
            raise ValueError("not stored here")
        path = (self.root / key).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError("outside storage root")
        return path.read_bytes()


def sigv4_headers(method: str, url: str, *, region: str, access_key: str, secret_key: str, payload: bytes = b"",
                  headers: dict[str, str] | None = None, now: datetime | None = None,
                  payload_hash: str | None = None) -> dict[str, str]:
    """AWS Signature Version 4 for one S3 request; every S3-compatible store (MinIO, Ceph, cloud providers in
    Kazakhstan) accepts it. Returns the headers to send, Authorization included."""
    now = now or datetime.now(timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    parts = urlsplit(url)
    signed = {k.lower(): v.strip() for k, v in (headers or {}).items()}
    signed["host"] = parts.netloc
    signed["x-amz-content-sha256"] = payload_hash or hashlib.sha256(payload).hexdigest()
    signed["x-amz-date"] = amz_date
    names = sorted(signed)
    canonical = "\n".join([
        method, quote(parts.path or "/", safe="/-_.~"), parts.query,
        "".join(f"{k}:{signed[k]}\n" for k in names), ";".join(names), signed["x-amz-content-sha256"]])
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = f"AWS4{secret_key}".encode()
    for part in (day, region, "s3", "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    return {**{k: v for k, v in signed.items() if k != "host"},
            "authorization": f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={';'.join(names)}, "
                             f"Signature={signature}"}


class S3Storage:
    """Photos in an S3-compatible bucket, addressed path-style ({endpoint}/{bucket}/{key}) so any provider works.
    public_base is what buyers' phones load from: the bucket's public address or a CDN in front of it."""

    def __init__(self, *, endpoint: str, bucket: str, region: str, access_key: str, secret_key: str,
                 public_base: str, client: httpx.Client | None = None):
        self.endpoint, self.bucket, self.region = endpoint.rstrip("/"), bucket, region
        self.access_key, self.secret_key = access_key, secret_key
        self.public_base = public_base.rstrip("/")
        self.client = client or httpx.Client(timeout=30)

    def _send(self, method: str, key: str, data: bytes = b"", headers: dict[str, str] | None = None) -> httpx.Response:
        url = f"{self.endpoint}/{self.bucket}/{key}"
        signed = sigv4_headers(method, url, region=self.region, access_key=self.access_key,
                               secret_key=self.secret_key, payload=data, headers=headers)
        r = self.client.request(method, url, content=data or None, headers=signed)
        if r.status_code >= 300:
            raise RuntimeError(f"storage {method} {key}: HTTP {r.status_code}")
        return r

    def put(self, data: bytes, *, owner_id: int, ext: str = "jpg") -> str:
        key = new_key(owner_id, ext)
        self._send("PUT", key, data, {"content-type": CONTENT_TYPES.get(ext, "application/octet-stream"),
                                      "cache-control": "public, max-age=31536000, immutable"})
        return f"{self.public_base}/{key}"

    def owns(self, url: str, owner_id: int | None = None) -> bool:
        return key_of(self.public_base, url, owner_id) is not None

    def read(self, url: str) -> bytes:
        key = key_of(self.public_base, url)
        if key is None:
            raise ValueError("not stored here")
        return self._send("GET", key).content


def make_storage(settings) -> Storage:
    if settings.s3_bucket:
        return S3Storage(endpoint=settings.s3_endpoint, bucket=settings.s3_bucket, region=settings.s3_region,
                         access_key=settings.s3_access_key, secret_key=settings.s3_secret_key,
                         public_base=settings.public_media_url)
    return LocalStorage(settings.media_dir, settings.public_media_url)
