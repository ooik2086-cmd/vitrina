"""Puts the frames of the approved Scroll 3D demo page (https://claude.ai/artifact/JC3hb8S7YMjPaxL6jBS1TG) into the
recorded demo answers, so the app's showcase shows exactly what that page shows: the blue shoe (listing 3) and the
black one (listing 1), 103 frames of one scan each at 1600 px, the six photo views at 3200 px.

    python3 app/demo/use_scan.py <folder with frames/blue and frames/black, as the page publishes them>

The scan renders already have a transparent background, so nothing goes through the cut-out model (which left a
light fringe on the earlier demo frames). Scrolling copies are made the way the server makes them (make_thumb).
Safe to run again.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from vitrina_api import cutout  # noqa: E402

HERE = Path(__file__).parent
MEDIA = HERE / "media"
BASE = "https://raw.githubusercontent.com/ooik2086-cmd/vitrina/claude/initial-code/app/demo/media/"
FRAMES = 103
# The page's photo views and its stops: the turn is frames 0-39, then the camera rises over the top (54), goes under
# the sole (74) and comes in close (102).
VIEWS = {"outer": 0, "front": 11, "inner": 20, "back": 30, "top": 54, "sole": 74, "detail": 102}
SHARP = {54, 74, 102}  # the stops: the page has 3200 px copies for zooming in (the cover stays 1600 px, it is shown everywhere)
SHOES = {3: ("blue", "көк"), 1: ("black", "қара")}


def put(data: bytes, ext: str) -> str:
    name = f"scan/{hashlib.sha256(data).hexdigest()[:32]}.{ext}"
    (MEDIA / name).parent.mkdir(parents=True, exist_ok=True)
    (MEDIA / name).write_bytes(data)
    return BASE + name


def media_of(folder: Path) -> list[dict]:
    frames = []
    for i in range(FRAMES):
        src = folder / (f"u{i:03d}.webp" if i in SHARP else f"f{i:03d}.webp")
        url = put(src.read_bytes(), "webp")
        thumb = put(cutout.make_thumb((folder / f"f{i:03d}.webp").read_bytes()), "webp")
        frames.append({"original_url": url, "processed_url": url, "angle": "frame", "thumb_url": thumb})
    photos = [{**frames[i], "angle": angle} for angle, i in VIEWS.items()]
    return photos + frames


def main() -> None:
    src = Path(sys.argv[1]) / "frames"
    answers = json.loads((HERE / "api.json").read_text())
    for listing_id, (shoe, color) in SHOES.items():
        media = media_of(src / shoe)

        # Only this listing and the orders for it change: other listings share some of the old photos.
        def fix(node):
            if isinstance(node, dict):
                if node.get("id") == listing_id and "media" in node:
                    node["media"] = media
                    node["color"] = color
                    node["title"] = f"Жеңіл жүгіру кроссовкасы, {color}"
                if node.get("listing_id") == listing_id and "listing_cover" in node:
                    node["listing_cover"] = media[0]["processed_url"]
                return {k: fix(v) for k, v in node.items()}
            if isinstance(node, list):
                return [fix(v) for v in node]
            return node

        answers = fix(answers)
    (HERE / "api.json").write_text(json.dumps(answers, ensure_ascii=False))


if __name__ == "__main__":
    main()
