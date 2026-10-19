"""The shared listing page's 360° turn, run in a real browser (share_page_browser.cjs). The other share page tests
read the page's text; only a browser shows that its script runs under the page's own Content-Security-Policy, turns
on arrival through small copies only, rests on the full photo, and follows a drag and the arrow keys.

Needs Node with the playwright package and a Chromium it can start; skipped without them, except on CI, which sets
VITRINA_BROWSER_TESTS=1 so a missing browser fails rather than skips."""
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
from vitrina_api.app import SHARE_CSP

SCRIPT = Path(__file__).with_name("share_page_browser.cjs")


def browser_ready() -> bool:
    """Whether a Chromium actually starts, not only whether the playwright package is there."""
    node = shutil.which("node")
    if not node:
        return False
    probe = "require('playwright').chromium.launch().then(b => b.close())"
    try:
        return subprocess.run([node, "-e", probe], capture_output=True, timeout=60).returncode == 0
    except subprocess.TimeoutExpired:
        return False


REQUIRED = os.environ.get("VITRINA_BROWSER_TESTS") == "1"


@unittest.skipUnless(REQUIRED or browser_ready(), "needs node with playwright and its Chromium")
class SharePageBrowserTests(ApiTestCase):
    # The turn starts at the frame matching the cover (f7), as the app does: small copies t7, t8, ... t6.
    small = [f"https://cdn.example/t{(7 + i) % 12}.webp" for i in range(12)]
    full = [f"https://cdn.example/c{(7 + i) % 12}.webp" for i in range(12)]

    def png(self, i: int) -> str:
        buf = io.BytesIO()
        Image.new("RGB", (40, 40), (i * 20 % 256, 90, 200 - i * 10 % 200)).save(buf, "PNG")
        return base64.b64encode(buf.getvalue()).decode()

    def run_page(self, *modes: str, fail=(), thumbs=True) -> dict:
        from vitrina_api.models import Listing
        frames = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(12)]
        listing = self.publish(photos=LISTING["photos"] + frames)
        with self.app.state.sessions() as db:
            row = db.get(Listing, listing["id"])
            for m in row.media:
                if m.angle == "frame":
                    n = m.original_url.rsplit("/f", 1)[1].split(".")[0]
                    m.processed_url = f"https://cdn.example/c{n}.webp"
                    m.thumb_url = f"https://cdn.example/t{n}.webp" if thumbs else None
            row.cover_frame = "https://cdn.example/f7.jpg"
            row.cover_frame_of = next(m.original_url for m in sorted(row.media, key=lambda m: m.position))
            db.commit()
        r = self.c.get(f"/l/{listing['id']}")
        self.assertEqual(r.status_code, 200)
        # The browser runs the page under exactly the policy the server sends.
        self.assertEqual(r.headers["content-security-policy"], SHARE_CSP)
        headers = {k: v for k, v in r.headers.items() if k.lower() not in ("content-length", "content-encoding")}
        images = {f"https://cdn.example/{kind}{i}.webp": self.png(i) for i in range(12) for kind in ("t", "c")}
        case = {"url": f"https://vitrina.test/l/{listing['id']}", "html": r.text, "headers": headers,
                "images": images, "fail": list(fail), "modes": list(modes)}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "case.json")
            path.write_text(json.dumps(case))
            done = subprocess.run(["node", str(SCRIPT), str(path)], capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        seen = json.loads(done.stdout)
        for mode in modes:
            self.assertEqual(seen[mode]["errors"], [], mode)  # the script ran, under the page's own policy
            self.assertEqual(seen[mode]["first"], self.full[0], mode)
            stage = seen[mode]["stage"]
            self.assertAlmostEqual(stage["width"], 412, delta=1)  # a square stage the width of the phone
            self.assertAlmostEqual(stage["height"], stage["width"], delta=1)
            self.assertTrue(seen[mode]["hint"].startswith("↔"))
        return seen

    @staticmethod
    def back(start: int, steps: int) -> int:
        """aria-valuenow (1..12) after turning steps frames back from start."""
        return (start - 1 - steps) % 12 + 1

    def test_turns_on_arrival_through_small_copies_then_follows_drag_and_keys(self):
        seen = self.run_page("auto")["auto"]
        # Once round, in order, from the frame after the cover's, only small copies, then the full photo at rest; a
        # press on the shoe that moved down rather than sideways did not stop it.
        self.assertEqual(seen["shown"], self.small[1:] + [self.small[0], self.full[0]])
        self.assertEqual(seen["restAfterTurn"], self.full[0])
        self.assertTrue(seen["restLoaded"])
        self.assertLessEqual(set(seen["askedBeforeTouch"]), set(self.small) | {self.full[0]})
        # Dragging right turns back (the app's direction): a third of the stage, past the first 8 px, is
        # 0.3 * 12 / 1.5 = 2.4 frames, so 2. The full photo comes once it rests.
        drag = seen["drag"]
        self.assertEqual(drag["during"], self.back(drag["before"], 2))
        self.assertEqual(drag["srcDuring"], self.small[drag["during"] - 1])
        self.assertEqual(drag["rest"], self.full[drag["during"] - 1])
        keys = seen["keys"]
        self.assertEqual((keys["left"], keys["right"]), (self.back(keys["before"], -1), self.back(keys["before"], 1)))

    def test_less_motion_means_no_turn_and_a_finger_scrolls_or_turns(self):
        seen = self.run_page("calm", "touch")
        calm = seen["calm"]
        self.assertEqual(calm["shown"], [])
        self.assertEqual(calm["askedBeforeTouch"], [self.full[0]])  # only the photo on the page
        self.assertEqual(calm["drag"]["during"], self.back(calm["drag"]["before"], 2))  # still turns under a hand
        # On a phone a swipe up that starts on the shoe scrolls the page and leaves the turn alone; a sideways swipe
        # after it turns the shoe, so the scroll the browser took over did not leave the turn stuck.
        touch = seen["touch"]
        self.assertGreater(touch["scroll"]["scrolled"], 50)
        self.assertEqual(touch["scroll"]["after"], touch["scroll"]["before"])
        self.assertEqual(touch["swipe"]["after"], self.back(touch["swipe"]["before"], 2))

    def test_data_saving_and_2g_fetch_nothing_until_touched(self):
        seen = self.run_page("saveData", "2g")
        for mode in ("saveData", "2g"):
            self.assertEqual(seen[mode]["askedBeforeTouch"], [self.full[0]], mode)
            self.assertEqual(seen[mode]["shown"], [], mode)
            self.assertNotEqual(seen[mode]["drag"]["during"], seen[mode]["drag"]["before"], mode)

    def test_without_small_copies_nothing_turns_on_its_own_and_a_drag_shows_full_photos(self):
        seen = self.run_page("auto", thumbs=False)["auto"]
        self.assertEqual((seen["shown"], seen["askedBeforeTouch"]), ([], [self.full[0]]))
        drag = seen["drag"]
        self.assertEqual(drag["srcDuring"], self.full[drag["during"] - 1])

    def test_a_small_copy_that_fails_is_stepped_over(self):
        seen = self.run_page("auto", fail=[self.small[3]])["auto"]
        self.assertEqual(seen["shown"], self.small[1:3] + self.small[4:] + [self.small[0], self.full[0]])


if __name__ == "__main__":
    unittest.main()
