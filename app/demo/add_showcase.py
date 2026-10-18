"""Brings the recorded demo answers (api.json) up to the scroll-turned showcase without re-recording everything:
small scrolling copies (thumb_url), the backdrop, and the top, sole and close-up photos after the turn.

    VITRINA_CUTOUT_MODEL=backend/models/isnet-general-use.onnx python3 app/demo/add_showcase.py

Each listing's shoe is recognised by comparing its first 360° frame with backend/demo/frames/<shoe>/f00.jpg; the
stop photos come from the same folder (rendered from the same scan, tools/demo-frames). Photos go through the
server's own code: normalize_image, the cut-out model when the listing's frames are cut out, make_thumb and
backdrop_for. Safe to run again: done photos are skipped.
"""
import hashlib
import json
import os
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from vitrina_api import cutout  # noqa: E402
from vitrina_api.storage import DETAIL_SIDE_PX, normalize_image  # noqa: E402

HERE = Path(__file__).parent
MEDIA = HERE / "media"
FRAMES = ROOT / "backend" / "demo" / "frames"
BASE = "https://raw.githubusercontent.com/ooik2086-cmd/vitrina/claude/initial-code/app/demo/media/"


def local(url: str) -> Path:
    return MEDIA / url.removeprefix(BASE)


def put(data: bytes, folder: str, ext: str) -> str:
    name = f"{folder}/{hashlib.sha256(data).hexdigest()[:32]}.{ext}"
    (MEDIA / name).parent.mkdir(parents=True, exist_ok=True)
    (MEDIA / name).write_bytes(data)
    return BASE + name


def shoe_of(frame: Path) -> str | None:
    """The demo shoe whose first frame is this one; None when none matches, so no other shoe's photos are added."""
    seen = Image.open(frame).convert("L").resize((64, 64))
    def gap(folder: Path) -> float:
        ref = Image.open(folder / "f00.jpg").convert("L").resize((64, 64))
        return ImageStat.Stat(ImageChops.difference(seen, ref)).mean[0]
    best = min((f for f in FRAMES.iterdir() if f.is_dir()), key=gap)
    return best.name if gap(best) < 2 else None


def main() -> None:
    model = os.environ.get("VITRINA_CUTOUT_MODEL")
    segment = cutout.load_segmenter(model) if model else None
    if segment is None:
        raise SystemExit("set VITRINA_CUTOUT_MODEL: the demo shows cut-outs, so the stops need them too")
    answers = json.loads((HERE / "api.json").read_text())
    done: dict[int, dict] = {}
    for key, listing in answers.items():
        if not (key.startswith("GET /listings/") and key.count("/") == 2):
            continue
        media = listing["media"]
        frames = [m for m in media if m["angle"] == "frame"]
        if not frames:
            continue
        folder = frames[0]["original_url"].removeprefix(BASE).split("/")[0]
        cut = all(m["processed_url"] for m in frames)
        shoe = shoe_of(local(frames[0]["original_url"]))
        have = {m["angle"] for m in media}
        stops = []
        for angle in ("top", "sole", "detail"):
            source = FRAMES / str(shoe) / f"{angle}.jpg"
            if shoe is None or angle in have or not source.exists():
                continue
            clean = normalize_image(source.read_bytes(), DETAIL_SIDE_PX)
            # Close-ups fill the photo: nothing to cut away, as on the server (listing_routes.CUTOUT_ANGLES).
            processed = cutout.process_photo(clean, segment) if cut and angle != "detail" else None
            stops.append({"original_url": put(clean, folder, "jpg"),
                          "processed_url": put(processed, folder, "webp") if processed else None, "angle": angle})
        # The stops follow the four sides, before any defect photo and the frames, as the server orders them.
        at = max(i for i, m in enumerate(media) if m["angle"] in ("outer", "front", "inner", "back")) + 1
        media[at:at] = stops
        for m in media:
            if not m.get("thumb_url"):
                source = m["processed_url"] or m["original_url"]
                m["thumb_url"] = put(cutout.make_thumb(local(source).read_bytes()), folder, "webp")
        first = next((m for m in media if m["angle"] == "frame" and m["processed_url"]), None)
        listing["backdrop"] = cutout.backdrop_for(local(first["processed_url"]).read_bytes()) if first else None
        done[listing["id"]] = listing
        print(f"listing {listing['id']}: {shoe}, {len(stops)} stops, backdrop {listing['backdrop']}")
    # Other answers (catalog, favourites, the seller's own list) carry the same listing: give them the same photos.
    def patch(node):
        if isinstance(node, dict):
            if node.get("id") in done and "media" in node:
                node["media"], node["backdrop"] = done[node["id"]]["media"], done[node["id"]]["backdrop"]
            for v in node.values():
                patch(v)
        elif isinstance(node, list):
            for v in node:
                patch(v)
    patch(answers)
    (HERE / "api.json").write_text(json.dumps(answers, ensure_ascii=False))


if __name__ == "__main__":
    main()
