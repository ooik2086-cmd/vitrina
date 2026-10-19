"""Background removal for showcase photos.

The only thing this module may change is which pixels are see-through. The product's pixels keep their
exact colour values: the cut-out is the original RGB with an alpha channel added, so the showcase style
(studio, premium, dynamic) shows around the shoe and never tints or reshapes it.

The segmentation model is optional. Without it, listings simply keep their original photos.
"""
from __future__ import annotations

import io
import logging
from pathlib import Path
from typing import Callable, Protocol

from PIL import Image, ImageChops, ImageDraw

log = logging.getLogger("vitrina.cutout")


class Segmenter(Protocol):
    def __call__(self, img: Image.Image) -> Image.Image:
        """Return an "L" mask the size of img: 255 = product, 0 = background."""


def fill_holes(mask: Image.Image, threshold: int = 128) -> Image.Image:
    """Make everything inside the product's outline opaque.

    Models sometimes mark a patch on the shoe (a stripe, a logo) as background. Only background that
    connects to the photo's border is real background, so enclosed "holes" are filled back in.
    """
    mask = mask.convert("L")
    w, h = mask.size
    binary = mask.point(lambda v: 255 if v >= threshold else 0)
    padded = Image.new("L", (w + 2, h + 2), 0)
    padded.paste(binary, (1, 1))
    ImageDraw.floodfill(padded, (0, 0), 128)  # mark background reachable from outside
    outside = padded.crop((1, 1, w + 1, h + 1)).point(lambda v: 0 if v == 128 else 255)
    return ImageChops.lighter(mask, outside)


def cut_out(img: Image.Image, mask: Image.Image) -> Image.Image:
    """Original RGB plus the mask as alpha. Colour values are copied, never recomputed."""
    rgba = img.convert("RGB").convert("RGBA")
    rgba.putalpha(fill_holes(mask.resize(img.size, Image.Resampling.BILINEAR)))
    return rgba


def encode_cutout(img: Image.Image) -> bytes:
    out = io.BytesIO()
    # WebP keeps transparency at a fraction of PNG's size; exact=True keeps RGB under transparent pixels.
    img.save(out, "WEBP", quality=90, method=4, exact=True)
    return out.getvalue()


def foreground_share(mask: Image.Image) -> float:
    hist = mask.convert("L").histogram()
    return sum(hist[128:]) / max(1, sum(hist))


class OnnxSegmenter:
    """Salient-object model run with onnxruntime on CPU.

    Known models (see backend/models/README.md for sources and licences):
      u2net              U²-Net, Apache-2.0, 320 px input, ~1 s per photo; the default, keeps white soles
      isnet-general-use  IS-Net, Apache-2.0, 1024 px input, ~2 s per photo
      u2netp             small U²-Net; not recommended, it drops white soles on light backdrops
    """

    PRESETS = {
        "isnet": (1024, (0.5, 0.5, 0.5), (1.0, 1.0, 1.0)),
        "u2net": (320, (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)),
    }

    def __init__(self, model_path: str):
        import numpy as np
        import onnxruntime as ort

        self._np = np
        name = Path(model_path).name
        self.size, mean, std = self.PRESETS["isnet" if name.startswith("isnet") else "u2net"]
        self._mean, self._std = np.array(mean, np.float32), np.array(std, np.float32)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        self._session = ort.InferenceSession(model_path, opts, providers=["CPUExecutionProvider"])
        self._input = self._session.get_inputs()[0].name

    def __call__(self, img: Image.Image) -> Image.Image:
        np = self._np
        small = img.convert("RGB").resize((self.size, self.size), Image.Resampling.LANCZOS)
        x = np.asarray(small, dtype=np.float32) / 255.0
        x = ((x - self._mean) / self._std).transpose(2, 0, 1)[None]
        pred = self._session.run(None, {self._input: x})[0][0, 0]
        lo, hi = float(pred.min()), float(pred.max())
        pred = (pred - lo) / (hi - lo + 1e-8)
        mask = Image.fromarray((pred * 255).astype("uint8"), "L")
        return mask.resize(img.size, Image.Resampling.BILINEAR)


def load_segmenter(model_path: str | None) -> Segmenter | None:
    if not model_path:
        return None
    if not Path(model_path).is_file():
        log.warning("cutout model not found at %s; background removal is off", model_path)
        return None
    try:
        return OnnxSegmenter(model_path)
    except Exception:  # missing onnxruntime or a broken model must not take the API down
        log.exception("cutout model failed to load; background removal is off")
        return None


def process_photo(data: bytes, segment: Segmenter, *, min_share: float = 0.03,
                  max_share: float = 0.95) -> bytes | None:
    """Cut-out bytes, or None when the mask is implausible (nothing found, or everything kept)."""
    img = Image.open(io.BytesIO(data))
    img.load()
    mask = segment(img)
    share = foreground_share(mask)
    if not min_share <= share <= max_share:
        return None
    return encode_cutout(cut_out(img, mask))


THUMB_SIDE_PX = 480
DARK_SHOE = 0.34  # median luminance of the shoe's own pixels below which it gets a light backdrop


def make_thumb(data: bytes) -> bytes:
    """A small WebP of a photo or cut-out for scrolling; transparency is kept, colours are only resampled."""
    img = Image.open(io.BytesIO(data))
    img.load()
    img = img.convert("RGBA") if img.mode in ("RGBA", "LA", "P") else img.convert("RGB")
    img.thumbnail((THUMB_SIDE_PX, THUMB_SIDE_PX), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, "WEBP", quality=82, method=4)
    return out.getvalue()


MATCH_SIZE = (64, 40)  # wide enough for a shoe seen from the side


def _match_print(data: bytes) -> Image.Image:
    """A small grey picture of the shoe alone, scaled to fill the same box whatever its size in the photo: the
    outline and the shading, which is what tells one angle of a shoe from another."""
    img = Image.open(io.BytesIO(data))
    img.load()
    img = img.convert("RGBA")
    box = img.getchannel("A").getbbox()
    if box and box != (0, 0, *img.size):
        img = img.crop(box)  # a cut-out: the shoe without the empty canvas around it
    flat = Image.new("RGBA", img.size, (128, 128, 128, 255))
    flat.alpha_composite(img)
    return flat.convert("L").resize(MATCH_SIZE, Image.Resampling.BILINEAR)


def closest_frame(cover: bytes, frames: list[bytes]) -> int | None:
    """Which of the 360° frames shows the shoe as the cover photo does, so a turn can start from the cover's angle.
    None when no frame can be read."""
    target = list(_match_print(cover).getdata())
    best, best_gap = None, None
    for i, data in enumerate(frames):
        try:
            seen = list(_match_print(data).getdata())
        except Exception:
            log.exception("frame %s could not be compared", i)
            continue
        gap = sum(abs(a - b) for a, b in zip(target, seen))
        if best_gap is None or gap < best_gap:
            best, best_gap = i, gap
    return best


def backdrop_for(cutout_bytes: bytes) -> str | None:
    """light or dark, from how bright the shoe itself is (transparent pixels are ignored); None without alpha."""
    img = Image.open(io.BytesIO(cutout_bytes))
    img.load()
    if img.mode != "RGBA":
        return None
    img.thumbnail((256, 256))
    lum = img.convert("RGB").convert("L")
    alpha = img.getchannel("A").point(lambda v: 255 if v >= 128 else 0)
    hist = lum.histogram(mask=alpha)
    count = sum(hist)
    if count == 0:
        return None
    # The median, not the mean: a black shoe on a big white sole is still a black shoe and needs a light backdrop.
    seen = 0
    for level, n in enumerate(hist):
        seen += n
        if seen * 2 >= count:
            return "light" if level / 255 < DARK_SHOE else "dark"
    return None


def process_listing_media(media: list, read: Callable[[str], bytes], write: Callable[[bytes], str],
                          segment: Segmenter) -> int:
    """Fill processed_url for each photo that has none. Returns how many were cut out."""
    done = 0
    for m in media:
        if m.processed_url:
            continue
        try:
            result = process_photo(read(m.original_url), segment)
        except Exception:
            log.exception("cutout failed for %s", m.original_url)
            continue
        if result is not None:
            m.processed_url = write(result)
            m.thumb_url = None  # the small copy follows the new cut-out
            done += 1
    return done
