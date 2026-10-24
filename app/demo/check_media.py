"""Checks the recorded demo answers: every photo's small scrolling copy, cut-out and original must show the same
picture, and every file must exist. The page draws the small copy and lays the sharp one over it, so two different
pictures in one photo show as two shoes on top of each other.

    python3 app/demo/check_media.py [api.json]

Exits 1 and names each photo that does not match.
"""
import json
import sys
from functools import cache
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

HERE = Path(__file__).parent
MEDIA = HERE / "media"
SIDE = 64
LIMIT = 12  # mean grey-level difference (0-255) above which two copies are different pictures


@cache
def load(url: str, root: Path) -> Image.Image:
    img = Image.open(root / url.split("/demo/media/", 1)[1])
    img.draft("RGB", (SIDE * 2, SIDE * 2))  # JPEGs decode at a fraction of their size
    return img.convert("RGBA").resize((SIDE, SIDE))


def grey(img: Image.Image) -> Image.Image:
    """The picture on a mid-grey ground."""
    ground = Image.new("RGBA", img.size, (128, 128, 128, 255))
    ground.alpha_composite(img)
    return ground.convert("L")


def gap(a: Image.Image, b: Image.Image, mask: Image.Image | None) -> float:
    """Mean grey-level difference, over the shoe alone when a cut-out mask is given, so a small shoe on a large empty
    ground does not water the difference down."""
    return ImageStat.Stat(ImageChops.difference(grey(a), grey(b)), mask).mean[0]


def compare(m: dict, root: Path) -> list[str]:
    """What is wrong with one photo: a missing file, or a copy that shows another picture."""
    urls = [u for u in (m.get("thumb_url"), m.get("processed_url"), m.get("original_url")) if u]
    try:
        imgs = {u: load(u, root) for u in urls}
    except FileNotFoundError as e:
        return [f"missing file {e.filename}"]
    cut = m.get("processed_url")
    mask = imgs[cut].getchannel("A").point(lambda a: 255 if a > 128 else 0) if cut else None
    if mask is not None and not mask.getbbox():
        mask = None  # an empty cut-out leaves nothing to compare over
    shown = cut or m["original_url"]
    return [f"{u.rsplit('/', 1)[1]} is not the same picture as {shown.rsplit('/', 1)[1]}"
            for u in urls if u != shown and gap(imgs[u], imgs[shown], mask) > LIMIT]


def check(answers: dict, root: Path) -> list[str]:
    problems: list[str] = []
    seen: dict[tuple, list[str]] = {}  # the same photo recurs in several answers
    owned: dict[int, set[str]] = {}  # every picture each listing has
    covers: list[tuple[str, int, str]] = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("listing_cover") and node.get("listing_id") is not None:
                covers.append((node["listing_cover"], node["listing_id"], f"listing {node['listing_id']} cover"))
            if isinstance(node.get("model"), dict) and "id" in node:
                # The 3D stage falls back to the photos without a word when its model is missing: say so here.
                for u in (node["model"].get("url"), node["model"].get("hq_url") or node["model"].get("url")):
                    path = root / u.split("/demo/media/", 1)[1] if u and "/demo/media/" in u else None
                    if path is None or not path.is_file() or path.read_bytes()[:4] != b"glTF":
                        problems.append(f"listing {node['id']} 3D model: not a model in the demo media: {u}")
                # The catalog card turns through these: a missing one leaves the shoe stuck mid-turn. The first
                # picture stands on the stage while the 3D loads: missing, the stage would wait empty.
                for u in node["model"].get("turn") or []:
                    path = root / u.split("/demo/media/", 1)[1] if "/demo/media/" in u else None
                    if path is None or not path.is_file() or path.read_bytes()[8:12] != b"WEBP":
                        problems.append(f"listing {node['id']} card turn: not in the demo media: {u}")
                # The 3D's first picture, carried inside the demo app (pubspec: demo/first/): missing, the stage
                # waits on a quiet line instead of showing the shoe at once.
                if first := node["model"].get("first_url"):
                    path = root.parent / "first" / first.split("/demo/first/", 1)[1] if "/demo/first/" in first else None
                    if path is None or not path.is_file() or path.read_bytes()[8:12] != b"WEBP":
                        problems.append(f"listing {node['id']} first 3D picture: not in app/demo/first: {first}")
            if isinstance(node.get("video"), dict) and "id" in node:
                # The «Видео» tab shows a broken player when its file is missing: say so here.
                for u, head in ((node["video"].get("url"), b"ftyp"), (node["video"].get("poster_url"), b"\xff\xd8")):
                    path = root / u.split("/demo/media/", 1)[1] if u and "/demo/media/" in u else None
                    if path is None or not path.is_file() or head not in path.read_bytes()[:12]:
                        problems.append(f"listing {node['id']} video: not in the demo media: {u}")
            if "media" in node and "id" in node and isinstance(node["media"], list):
                for m in node["media"]:
                    owned.setdefault(node["id"], set()).update(
                        u for u in (m.get("thumb_url"), m.get("processed_url"), m.get("original_url")) if u)
                for i, m in enumerate(node["media"]):
                    key = (m.get("thumb_url"), m.get("processed_url"), m.get("original_url"))
                    if key not in seen:
                        seen[key] = compare(m, root)
                    where = f"listing {node['id']} photo {i} ({m.get('angle')})"
                    problems.extend(f"{where}: {p}" for p in seen[key])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(answers)
    for url, listing, where in covers:
        if listing in owned and url not in owned[listing]:
            problems.append(f"{where}: {url.rsplit('/', 1)[1]} is not one of this listing's photos")
        elif not (root / url.split("/demo/media/", 1)[1]).is_file():
            problems.append(f"{where}: missing file {url.rsplit('/', 1)[1]}")
    return list(dict.fromkeys(problems))


def main() -> None:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "api.json"
    problems = check(json.loads(path.read_text()), MEDIA)
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
