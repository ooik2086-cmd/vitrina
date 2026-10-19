"""Fills angle_frames in the recorded demo answers the way the server's media job does
(listing_routes.match_turn_frames): for each side photo, the frame of one turn showing that side square on. Only
listings whose frames and side photos all have cut-outs and small copies get them.

    python3 app/demo/match_sides.py [api.json]
"""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent.parent / "backend"))
from vitrina_api import cutout  # noqa: E402
from vitrina_api.serializers import one_turn  # noqa: E402

SIDES = ("back", "front", "inner", "outer")


def read(url):
    return (HERE / "media" / url.split("/demo/media/")[1]).read_bytes()


def sides_of(listing, cache={}):
    if listing["id"] not in cache:
        media = [SimpleNamespace(**m) for m in listing["media"]]
        frames = [m for m in media if m.angle == "frame"]
        turn, _ = one_turn(media)
        cut = lambda m: m.processed_url and m.thumb_url  # noqa: E731
        photos = {s: m for s in SIDES if (m := next((m for m in media if m.angle == s), None)) and cut(m)}
        found = {}
        if frames and all(cut(m) for m in frames) and photos and len(turn) >= 8:
            found = cutout.side_frames({s: read(m.thumb_url) for s, m in photos.items()},
                                       [read(m.thumb_url) for m in turn])
        cache[listing["id"]] = {s: turn[k].original_url for s, k in sorted(found.items())}
    return cache[listing["id"]]


def fill(node):
    if isinstance(node, dict):
        if "media" in node and "cover_frame" in node:
            node["angle_frames"] = sides_of(node)
        for value in node.values():
            fill(value)
    elif isinstance(node, list):
        for value in node:
            fill(value)


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "api.json"
    data = json.loads(path.read_text())
    fill(data)
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
