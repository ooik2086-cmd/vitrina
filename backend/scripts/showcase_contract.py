"""Writes contracts/showcase_parts_demo.json: how the demo listings (app/demo/api.json) split into showcase parts,
which the app's and the server's tests check. Run after re-recording the demo: python -m scripts.showcase_contract"""
import json
import re
from pathlib import Path
from types import SimpleNamespace

from vitrina_api.serializers import one_turn, showcase_parts

ROOT = Path(__file__).resolve().parents[2]
ABOUT = ("How the demo listings split into showcase parts (see showcase_parts.json): each part's size and first "
         "frame, and the frames in one turn. Written by backend/scripts/showcase_contract.py.")


def split(listing: dict) -> dict:
    media = [SimpleNamespace(angle=m["angle"], original_url=m["original_url"]) for m in listing["media"]]
    parts = showcase_parts(media)
    return {"sizes": [len(p) for p in parts], "starts": [p[0].original_url for p in parts],
            "turn": len(one_turn(media)[0])}


def main() -> None:
    demo = json.loads((ROOT / "app/demo/api.json").read_text())
    rows = [f"  {json.dumps(k)}: {json.dumps(split(v))}" for k, v in demo.items()
            if re.fullmatch(r"GET /listings/\d+", k)]
    (ROOT / "contracts/showcase_parts_demo.json").write_text(
        "{\n " + f'"about": {json.dumps(ABOUT)},\n "listings": {{\n' + ",\n".join(rows) + "\n }\n}\n")


if __name__ == "__main__":
    main()
