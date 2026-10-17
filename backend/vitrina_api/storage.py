"""Photo storage. Uploads are decoded, upright-rotated and re-encoded so no EXIF (GPS, device) survives."""
from __future__ import annotations

import io
import secrets
from pathlib import Path

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


class LocalStorage:
    """Development storage on disk. Production swaps this for an S3-compatible bucket hosted in Kazakhstan."""

    def __init__(self, root: str, public_base: str):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.public_base = public_base.rstrip("/")

    def put(self, data: bytes, *, owner_id: int) -> str:
        name = f"{owner_id}/{secrets.token_hex(16)}.jpg"
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return f"{self.public_base}/{name}"

    def owns(self, url: str) -> bool:
        return url.startswith(self.public_base + "/")
