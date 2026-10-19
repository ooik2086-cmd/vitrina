"""The shared listing page's 360° turn, run in a real browser (share_page_browser.cjs). The other share page tests
read the page's text; only a browser shows that its script runs under the page's own Content-Security-Policy, turns
on arrival through small copies only, rests on the full photo, and follows a drag and the arrow keys.

Needs Node with the playwright package and a Chromium (as on CI, which sets VITRINA_BROWSER_TESTS=1 so a missing
browser fails rather than skips)."""
from __future__ import annotations

import base64
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from tests.test_api import ApiTestCase, LISTING

SCRIPT = Path(__file__).with_name("share_page_browser.cjs")


def browser_ready() -> bool:
    node = shutil.which("node")
    return bool(node) and subprocess.run([node, "-e", "require('playwright')"], capture_output=True).returncode == 0


REQUIRED = os.environ.get("VITRINA_BROWSER_TESTS") == "1"


@unittest.skipUnless(REQUIRED or browser_ready(), "needs node with playwright")
class SharePageBrowserTests(ApiTestCase):
    def png(self, i: int) -> str:
        buf = io.BytesIO()
        Image.new("RGB", (40, 40), (i * 20 % 256, 90, 200 - i * 10 % 200)).save(buf, "PNG")
        return base64.b64encode(buf.getvalue()).decode()

    def run_page(self, fail=()) -> dict:
        from vitrina_api.models import Listing
        frames = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(12)]
        listing = self.publish(photos=LISTING["photos"] + frames)
        with self.app.state.sessions() as db:
            row = db.get(Listing, listing["id"])
            for m in row.media:
                if m.angle == "frame":
                    n = m.original_url.rsplit("/f", 1)[1].split(".")[0]
                    m.processed_url, m.thumb_url = f"https://cdn.example/c{n}.webp", f"https://cdn.example/t{n}.webp"
            row.cover_frame = "https://cdn.example/f7.jpg"
            row.cover_frame_of = next(m.original_url for m in sorted(row.media, key=lambda m: m.position))
            db.commit()
        r = self.c.get(f"/l/{listing['id']}")
        self.assertEqual(r.status_code, 200)
        headers = {k: v for k, v in r.headers.items() if k.lower() not in ("content-length", "content-encoding")}
        self.assertIn("content-security-policy", {k.lower() for k in headers})
        images = {f"https://cdn.example/{kind}{i}.webp": self.png(i) for i in range(12) for kind in ("t", "c")}
        case = {"url": f"https://vitrina.test/l/{listing['id']}", "html": r.text, "headers": headers,
                "images": images, "fail": list(fail)}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "case.json")
            path.write_text(json.dumps(case))
            done = subprocess.run(["node", str(SCRIPT), str(path)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        return json.loads(done.stdout)

    # The turn starts at the frame matching the cover (f7), as the app does: small copies t7, t8, ... t6.
    small = [f"https://cdn.example/t{(7 + i) % 12}.webp" for i in range(12)]
    full = [f"https://cdn.example/c{(7 + i) % 12}.webp" for i in range(12)]

    @staticmethod
    def back(start: int, steps: int) -> int:
        """aria-valuenow (1..12) after turning steps frames back from start."""
        return (start - 1 - steps) % 12 + 1

    def test_turns_on_arrival_through_small_copies_then_follows_drag_and_keys(self):
        seen = self.run_page()["auto"]
        self.assertEqual(seen["errors"], [])  # the script ran under the page's own Content-Security-Policy
        self.assertEqual(seen["first"], self.full[0])
        turned = seen["shown"][1:]
        # Once round through every small copy, never a full photo while turning, then the full photo at rest; a
        # vertical move on the shoe early in the turn did not stop it.
        self.assertEqual(sorted(set(turned) - {self.full[0]}), sorted(self.small))
        self.assertEqual(seen["restAfterTurn"], self.full[0])
        self.assertLessEqual(set(seen["askedBeforeTouch"]), set(self.small) | {self.full[0]})
        # Dragging right turns back a few frames (the app's direction), and the full photo comes once it rests.
        drag = seen["drag"]
        self.assertIn(drag["during"], [self.back(drag["before"], s) for s in (2, 3)])
        self.assertEqual(drag["srcDuring"], self.small[drag["during"] - 1])
        self.assertEqual(drag["rest"], self.full[drag["during"] - 1])
        self.assertEqual(seen["vertical"]["after"], seen["vertical"]["before"])
        keys = seen["keys"]
        self.assertEqual((keys["left"], keys["right"]), (self.back(keys["before"], -1), self.back(keys["before"], 1)))

    def test_less_motion_means_no_turn_and_nothing_fetched_until_touched(self):
        seen = self.run_page()["calm"]
        self.assertEqual(seen["errors"], [])
        self.assertEqual(seen["shown"], [self.full[0]])
        self.assertEqual(seen["askedBeforeTouch"], [self.full[0]])  # only the photo on the page
        self.assertNotEqual(seen["drag"]["during"], seen["drag"]["before"])  # still turns under a finger

    def test_a_small_copy_that_fails_is_stepped_over(self):
        seen = self.run_page(fail=[self.small[3]])["auto"]
        self.assertEqual(seen["errors"], [])
        self.assertNotIn(self.small[3], seen["shown"])
        self.assertIn(self.small[4], seen["shown"])  # it carried on past it
        self.assertEqual(seen["restAfterTurn"], self.full[0])


if __name__ == "__main__":
    unittest.main()
