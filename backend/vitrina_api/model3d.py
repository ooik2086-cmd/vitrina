"""A shoe's 3D model as the staff console uploads it: checked to be a glTF binary the app's viewer opens on its own,
and the model's first picture, made in the console from the model as the listing page's stage opens it."""
from __future__ import annotations

import io
import json
import struct

from PIL import Image, UnidentifiedImageError

from .errors import ApiError

# The page loads the whole model before the shoe turns: on a phone's mobile data a few MB is the most it should wait.
MODEL_MAX_BYTES = 8 * 1024 * 1024
FIRST_MAX_BYTES = 3 * 1024 * 1024
FIRST_SIDE_PX = 1080  # as the demo's first pictures: sharp on the widest phone stage
FIRST_MIN_PX = 400
FIRST_MAX_PX = 4096
# Pictures inside the model: a phone decodes each to full size in its graphics memory (a 4096² one with its smaller
# copies is ~90 MB), so a mid-range phone's WebView would lose its drawing for a model a desktop shows well.
TEXTURE_MAX_SIDE = 4096
TEXTURE_MAX_AREA = 3 * 4096 * 4096
# Need a decoder the app's viewer does not carry: three.js refuses a file that merely lists one of them as used.
NEEDS_DECODER = {"KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_meshopt_compression",
                 "KHR_texture_basisu"}
# What three.js r160's GLTFLoader opens by itself; a file that requires anything else would not open on the phone.
OPENS = {"KHR_texture_transform", "KHR_mesh_quantization", "KHR_lights_punctual", "KHR_materials_variants",
         "EXT_texture_webp", "EXT_texture_avif", "EXT_mesh_gpu_instancing"}
IMAGE_TYPES = {"image/png", "image/jpeg", "image/webp"}


def _bad(why: str) -> ApiError:
    return ApiError(422, "bad_model", why)


def _chunks(data: bytes) -> tuple[dict, bytes]:
    if len(data) < 20:
        raise _bad("too short")
    magic, version, length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise _bad("not a glTF 2 binary")
    if length != len(data):
        raise _bad("length does not match")
    json_len, json_type = struct.unpack_from("<I4s", data, 12)
    if json_type != b"JSON" or 20 + json_len > len(data):
        raise _bad("no JSON chunk")
    try:
        gltf = json.loads(data[20:20 + json_len].decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise _bad("JSON chunk unreadable") from None
    at, binary = 20 + json_len, b""
    if at + 8 <= len(data):
        bin_len, bin_type = struct.unpack_from("<I4s", data, at)
        if bin_type == b"BIN\0" and at + 8 + bin_len <= len(data):
            binary = data[at + 8:at + 8 + bin_len]
    return gltf, binary


def _reaches_mesh(gltf: dict) -> bool:
    nodes, scenes = gltf.get("nodes") or [], gltf.get("scenes") or []
    scene = scenes[gltf.get("scene", 0)] if scenes else None
    todo, seen = list((scene or {}).get("nodes") or []), set()
    while todo:
        i = todo.pop()
        if i in seen or not isinstance(i, int) or not 0 <= i < len(nodes):
            continue
        seen.add(i)
        if nodes[i].get("mesh") is not None:
            return True
        todo.extend(nodes[i].get("children") or [])
    return False


def check_glb(data: bytes) -> list[str]:
    """The model's own colour names (KHR_materials_variants), or 422 bad_model unless [data] is one self-contained
    glTF 2.0 binary the viewer can open: everything in the file itself (a model that loads files from another
    address would show what that address sends, and tell it who looks), a shoe its scene shows, no compression the
    viewer cannot undo, no pictures too large for a phone."""
    gltf, binary = _chunks(data)
    try:
        if not isinstance(gltf, dict) or not str((gltf.get("asset") or {}).get("version", "")).startswith("2."):
            raise _bad("not glTF 2.0")
        if not gltf.get("meshes") or not _reaches_mesh(gltf):
            raise _bad("no shoe in its scene")
        buffers = gltf.get("buffers") or []
        for kind in ("buffers", "images"):
            for item in gltf.get(kind) or []:
                if item.get("uri") is not None:
                    raise _bad(f"{kind} load from {str(item['uri'])[:60]}")
        if buffers and len(binary) < int(buffers[0].get("byteLength", 0)):
            raise _bad("its data is cut short")
        used = set(gltf.get("extensionsUsed") or []) | set(gltf.get("extensionsRequired") or [])
        if used & NEEDS_DECODER:
            raise _bad("needs " + ", ".join(sorted(used & NEEDS_DECODER)))
        unknown = {e for e in gltf.get("extensionsRequired") or []
                   if e not in OPENS and not str(e).startswith("KHR_materials_")}
        if unknown:
            raise _bad("needs " + ", ".join(sorted(map(str, unknown)))[:200])
        views, area = gltf.get("bufferViews") or [], 0
        for image in gltf.get("images") or []:
            if image.get("mimeType") not in IMAGE_TYPES:
                raise _bad(f"image type {str(image.get('mimeType'))[:40]}")
            view = views[image["bufferView"]]
            start = int(view.get("byteOffset", 0))
            try:
                with Image.open(io.BytesIO(binary[start:start + int(view["byteLength"])])) as img:
                    w, h = img.size
            except (UnidentifiedImageError, OSError, Image.DecompressionBombError):
                raise _bad("a picture inside it does not open") from None
            if max(w, h) > TEXTURE_MAX_SIDE:
                raise _bad(f"a picture inside it is {w}x{h}: at most {TEXTURE_MAX_SIDE} px a side")
            area += w * h
        if area > TEXTURE_MAX_AREA:
            raise _bad(f"its pictures are too large together: at most three {TEXTURE_MAX_SIDE} px squares")
        root = (gltf.get("extensions") or {}).get("KHR_materials_variants") or {}
        return [str(v.get("name")) for v in root.get("variants") or []]
    except ApiError:
        raise
    except (AttributeError, TypeError, KeyError, IndexError, ValueError):
        # Not shaped as glTF says (a list where an object goes, an index past the end): not something we can open.
        raise _bad("its JSON is not shaped as glTF") from None


def first_picture(data: bytes) -> bytes:
    """The console's render of the model, kept as it is (cut out, square) at FIRST_SIDE_PX, as WebP."""
    try:
        img = Image.open(io.BytesIO(data))
        if img.format != "PNG":
            raise ApiError(415, "unsupported_media", f"format {img.format}")
        if img.width != img.height or not FIRST_MIN_PX <= img.width <= FIRST_MAX_PX:
            raise ApiError(422, "bad_first_picture",
                           f"{img.width}x{img.height}: must be square, {FIRST_MIN_PX}-{FIRST_MAX_PX}px")
        img.load()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as exc:
        raise ApiError(415, "unsupported_media", str(exc)) from exc
    alpha = img.convert("RGBA").getchannel("A")
    if alpha.getextrema()[0] == 255:
        raise ApiError(422, "bad_first_picture", "not cut out: the app draws the scene behind it")
    # A blank picture (the drawing was lost, or the shoe is off the camera) would stand on the stage as nothing.
    shown = sum(alpha.point(lambda a: 255 if a > 128 else 0).histogram()[255:])
    if shown < alpha.width * alpha.height // 100:
        raise ApiError(422, "bad_first_picture", "the shoe is not in it")
    img = img.convert("RGBA")
    if img.width != FIRST_SIDE_PX:
        img = img.resize((FIRST_SIDE_PX, FIRST_SIDE_PX), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, "WEBP", quality=90, method=6)
    return out.getvalue()
