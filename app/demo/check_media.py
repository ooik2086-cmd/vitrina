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


def grey(img: Image.Image, mask: Image.Image | None) -> Image.Image:
    """The picture on a mid-grey ground, with only the shoe kept when a cut-out mask is given."""
    ground = Image.new("RGBA", img.size, (128, 128, 128, 255))
    ground.alpha_composite(img)
    out = ground.convert("L")
    return out if mask is None else Image.composite(out, Image.new("L", out.size, 128), mask)


def gap(a: Image.Image, b: Image.Image) -> float:
    return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]


def check(answers: dict, root: Path) -> list[str]:
    problems, seen = [], set()

    def walk(node):
        if isinstance(node, dict):
            if "media" in node and "id" in node and isinstance(node["media"], list):
                for i, m in enumerate(node["media"]):
                    key = (m.get("thumb_url"), m.get("processed_url"), m.get("original_url"))
                    if key in seen:
                        continue
                    seen.add(key)
                    where = f"listing {node['id']} photo {i} ({m.get('angle')})"
                    urls = [u for u in (m.get("thumb_url"), m.get("processed_url"), m.get("original_url")) if u]
                    try:
                        imgs = {u: load(u, root) for u in urls}
                    except FileNotFoundError as e:
                        problems.append(f"{where}: missing file {e.filename}")
                        continue
                    cut = m.get("processed_url")
                    mask = imgs[cut].getchannel("A").point(lambda a: 255 if a > 128 else 0) if cut else None
                    shown = cut or m["original_url"]
                    for u in urls:
                        if u != shown and gap(grey(imgs[u], mask), grey(imgs[shown], mask)) > LIMIT:
                            problems.append(f"{where}: {u.rsplit('/', 1)[1]} is not the same picture as "
                                            f"{shown.rsplit('/', 1)[1]}")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(answers)
    return problems


def main() -> None:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "api.json"
    problems = check(json.loads(path.read_text()), MEDIA)
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
