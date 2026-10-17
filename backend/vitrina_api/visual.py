"""Search by photo: find listings that look like a picture the buyer takes or uploads.

Each listing gets one vector from its main photo (the cut-out version when there is one, so the backdrop
does not count). A query photo gets a vector the same way, and listings are ranked by cosine similarity.

The vector joins two parts:
  - shape and texture: the 1280 pooled features of MobileNetV2 (ONNX model zoo, Apache-2.0), read from the
    layer before the classifier, so no ImageNet class names are involved;
  - colour: a hue/lightness histogram of the shoe's own pixels, because "a white sneaker" and "a black
    sneaker" of the same model must not look identical to search.

The model is optional. Without it, image search answers 503 and the rest of the API is unaffected.
"""
from __future__ import annotations

import io
import logging
from pathlib import Path

from PIL import Image

log = logging.getLogger(__name__)

MODEL_NAME = "mobilenetv2-12+hsv1"
COLOR_WEIGHT = 0.5  # share of the colour part in the final cosine score


def _flatten_on_white(img: Image.Image) -> tuple[Image.Image, Image.Image | None]:
    """RGB on white plus the alpha mask (None when the photo has no transparency)."""
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        base = Image.new("RGB", rgba.size, (255, 255, 255))
        base.paste(rgba, mask=rgba.getchannel("A"))
        return base, rgba.getchannel("A")
    return img.convert("RGB"), None


def color_histogram(img: Image.Image, mask: Image.Image | None, np):
    """12 hues x 3 lightness bands plus 3 grey bands, over the product's pixels only."""
    small = img.resize((96, 96))
    hsv = np.asarray(small.convert("HSV"), dtype=np.float32) / 255.0
    rgb = np.asarray(small, dtype=np.float32) / 255.0
    keep = np.ones(hsv.shape[:2], bool) if mask is None else np.asarray(mask.resize((96, 96))) > 128
    if mask is None:  # no cut-out: ignore near-white backdrop pixels
        keep &= rgb.min(axis=2) < 0.92
    h, s, v = hsv[..., 0][keep], hsv[..., 1][keep], hsv[..., 2][keep]
    hist = np.zeros(39, np.float32)
    if h.size == 0:
        return hist
    grey = s < 0.2
    band = np.minimum((v * 3).astype(int), 2)
    np.add.at(hist, 36 + band[grey], 1)
    hue = np.minimum((h[~grey] * 12).astype(int), 11)
    np.add.at(hist, hue * 3 + band[~grey], 1)
    return hist / max(1.0, float(hist.sum()))


class Embedder:
    SIZE = 224

    def __init__(self, model_path: str):
        import numpy as np
        import onnx
        import onnxruntime as ort

        self._np = np
        model = onnx.load(model_path)
        gemm = next(n for n in reversed(model.graph.node) if n.op_type == "Gemm")
        features = gemm.input[0]  # pooled features feeding the ImageNet classifier
        model.graph.output.append(onnx.helper.make_tensor_value_info(features, onnx.TensorProto.FLOAT, None))
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        self._session = ort.InferenceSession(model.SerializeToString(), opts, providers=["CPUExecutionProvider"])
        self._input = self._session.get_inputs()[0].name
        self._features = features

    def __call__(self, data: bytes):
        np = self._np
        img = Image.open(io.BytesIO(data))
        img.load()
        rgb, mask = _flatten_on_white(img)
        x = np.asarray(rgb.resize((self.SIZE, self.SIZE), Image.Resampling.BILINEAR), np.float32) / 255.0
        x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array([0.229, 0.224, 0.225], np.float32)
        feat = self._session.run([self._features], {self._input: x.transpose(2, 0, 1)[None]})[0].reshape(-1)
        return combine(feat, color_histogram(rgb, mask, np), np)


def combine(shape, colour, np):
    shape = shape / (np.linalg.norm(shape) + 1e-8)
    colour = colour / (np.linalg.norm(colour) + 1e-8)
    return np.concatenate([shape * np.sqrt(1 - COLOR_WEIGHT), colour * np.sqrt(COLOR_WEIGHT)]).astype(np.float32)


def load_embedder(model_path: str | None) -> Embedder | None:
    if not model_path:
        return None
    if not Path(model_path).is_file():
        log.warning("image-search model not found at %s; search by photo is off", model_path)
        return None
    try:
        return Embedder(model_path)
    except Exception:
        log.exception("image-search model failed to load; search by photo is off")
        return None
