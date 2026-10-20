"""Puts the frames of the approved Scroll 3D demo page (https://claude.ai/artifact/JC3hb8S7YMjPaxL6jBS1TG) into the
recorded demo answers, so the app's showcase shows exactly what that page shows: the blue shoe (listing 3) and the
black one (listing 1), 103 frames of one scan each at 1600 px. The stops (outer, front, inner, back, top, sole,
close-up) are frames of that same scan, the top, sole and close-up from its sharper renders.

    python3 app/demo/use_scan.py <folder with frames/blue and frames/black, as the page publishes them>

The pink (beach) and black-and-pink (street) shoes of listings 4, 2 and 6 are scanned the same way from the same
model by tools/demo-frames/scan.js (their 36-frame turns with separate top and sole photos jumped between views, and
the cut-out model ate into their white soles):

    python3 app/demo/use_scan.py <folder with frames/beach and frames/street> --only 2,4,6

The scan renders already have a transparent background, so nothing goes through the cut-out model (which left a
light fringe on the earlier demo frames). Scrolling copies are made the way the server makes them (make_thumb).
Safe to run again. Afterwards run match_sides.py, which matches the side photos to their frames.
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
# Listing: scan folder, and the colour the listing is renamed to (None keeps its own title and colour).
SHOES = {3: ("blue", "көк"), 1: ("black", "қара"), 4: ("beach", None), 2: ("street", None), 6: ("street", None)}
FIRST = {1, 3}  # the scans of the approved page; the rest are listed with --only


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
    only = {int(x) for x in sys.argv[3].split(",")} if len(sys.argv) > 3 and sys.argv[2] == "--only" else FIRST
    answers = json.loads((HERE / "api.json").read_text())
    for listing_id, (shoe, color) in SHOES.items():
        if listing_id not in only:
            continue
        scan = media_of(src / shoe)

        # Only this listing and the orders for it change: other listings share some of the old photos.
        def fix(node):
            if isinstance(node, dict):
                if node.get("id") == listing_id and "media" in node:
                    # Photos that are not views of the shoe (a defect, the label) stay as the seller took them.
                    own = [m for m in node["media"] if m.get("angle") not in {*VIEWS, "frame"}]
                    node["media"] = scan + own
                    if "cover_frame" in node:
                        node["cover_frame"] = None  # the scan starts at its cover: frame 0 is the outer side
                    if color:
                        node["color"] = color
                        node["title"] = f"Жеңіл жүгіру кроссовкасы, {color}"
                if node.get("listing_id") == listing_id and "listing_cover" in node:
                    node["listing_cover"] = scan[0]["processed_url"]
                return {k: fix(v) for k, v in node.items()}
            if isinstance(node, list):
                return [fix(v) for v in node]
            return node

        answers = fix(answers)
    (HERE / "api.json").write_text(json.dumps(answers, ensure_ascii=False))


if __name__ == "__main__":
    main()
