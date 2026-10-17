"""Photo storage. Uploads are decoded, upright-rotated and re-encoded so no EXIF (GPS, device) survives."""
from __future__ import annotations

import hashlib
import hmac
import io
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, urlsplit

import httpx

from PIL import Image, ImageOps, UnidentifiedImageError

from .errors import ApiError

MAX_UPLOAD_BYTES = 12 * 1024 * 1024
MAX_SIDE_PX = 2000
MIN_SIDE_PX = 400
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}
# Decompression-bomb guard: refuse anything that would decode beyond ~50 MP.
Image.MAX_IMAGE_PIXELS = 50_000_000


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

    def owns(self, url: str) -> bool: ...

    def read(self, url: str) -> bytes: ...


def new_key(owner_id: int, ext: str) -> str:
    return f"{owner_id}/{secrets.token_hex(16)}.{ext}"


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

    def owns(self, url: str) -> bool:
        return url.startswith(self.public_base + "/")

    def read(self, url: str) -> bytes:
        if not self.owns(url):
            raise ValueError("not stored here")
        path = (self.root / url[len(self.public_base) + 1:]).resolve()
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

    def owns(self, url: str) -> bool:
        return url.startswith(self.public_base + "/")

    def read(self, url: str) -> bytes:
        if not self.owns(url):
            raise ValueError("not stored here")
        key = url[len(self.public_base) + 1:]
        if ".." in key.split("/"):
            raise ValueError("outside storage root")
        return self._send("GET", key).content


def make_storage(settings) -> Storage:
    if settings.s3_bucket:
        return S3Storage(endpoint=settings.s3_endpoint, bucket=settings.s3_bucket, region=settings.s3_region,
                         access_key=settings.s3_access_key, secret_key=settings.s3_secret_key,
                         public_base=settings.public_media_url)
    return LocalStorage(settings.media_dir, settings.public_media_url)
