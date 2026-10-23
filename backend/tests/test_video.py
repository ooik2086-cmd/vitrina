"""The seller's own video of a pair (the «Видео» tab): checked on arrival, made smaller apart from the request."""
import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path

from tests.test_api import ApiTestCase
from vitrina_api import video_routes
from vitrina_api.deps import now_utc
from vitrina_api.models import Listing

FFMPEG = shutil.which("ffmpeg") and shutil.which("ffprobe")
CLIPS: dict[str, bytes] = {}


def clip(seconds: float, size: str = "1280x720", rate: int = 30) -> bytes:
    """A test pattern with a tone, as a phone would send it (MP4, H.264, AAC)."""
    key = f"{seconds}-{size}-{rate}"
    if key not in CLIPS:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "c.mp4"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            f"testsrc2=size={size}:rate={rate}:duration={seconds}", "-f", "lavfi", "-i",
                            f"sine=frequency=440:duration={seconds}", "-c:v", "libx264", "-preset", "ultrafast",
                            "-c:a", "aac", "-shortest", "-metadata", "location=+43.2381+076.9452/", str(out)],
                           check=True)
            CLIPS[key] = out.read_bytes()
    return CLIPS[key]


def probe(data: bytes) -> dict:
    with tempfile.NamedTemporaryFile(suffix=".mp4") as f:
        f.write(data)
        f.flush()
        run = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                              "format=duration:format_tags:stream=codec_name,width,height", "-of", "json", f.name],
                             capture_output=True, check=True)
    return json.loads(run.stdout)


@unittest.skipUnless(FFMPEG, "ffmpeg is not installed here")
class ListingVideoTests(ApiTestCase):
    def send(self, lid, data, token=None, name="v.mp4"):
        return self.c.post(f"/api/v1/listings/{lid}/video", files={"file": (name, data, "video/mp4")},
                           headers=self.h(token or self.seller))

    def page(self, lid, token=None):
        return self.c.get(f"/api/v1/listings/{lid}", headers=self.h(token) if token else {}).json()

    def test_a_minute_of_video_is_made_720p_with_a_poster_and_shown_to_buyers(self):
        listing = self.publish()
        lid, version = listing["id"], listing["photos_version"]
        self.assertIsNone(listing["video"])
        r = self.send(lid, clip(4, "1920x1080", 60))
        self.assertEqual(r.status_code, 202, r.text)
        # The answer comes before the video is made; the page shows it being made only to its seller.
        self.assertEqual((r.json()["video"]["state"], r.json()["video"]["seconds"]), ("processing", 4))
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]["video"]
        page = self.page(lid)  # the job ran after the answer (as it does here)
        self.assertEqual(mine["state"], "ready")
        video = page["video"]
        self.assertEqual((video["state"], video["seconds"]), ("ready", 4))
        stored = self.app.state.storage.read(video["url"])
        info = probe(stored)
        self.assertEqual(sorted(s["codec_name"] for s in info["streams"]), ["aac", "h264"])
        self.assertEqual([(s["width"], s["height"]) for s in info["streams"] if s["codec_name"] == "h264"],
                         [(1280, 720)])  # the short side 720, never larger
        self.assertNotIn("location", json.dumps(info["format"].get("tags", {})))  # where it was filmed is dropped
        self.assertLess(len(stored), len(clip(4, "1920x1080", 60)) * 2)
        self.assertEqual(self.app.state.storage.read(video["poster_url"])[:2], b"\xff\xd8")  # a JPEG poster
        self.assertNotEqual(page["photos_version"], version)  # a page read before it cannot order
        # The order keeps the video the buyer watched.
        body = {"listing_id": lid, "size_id": page["sizes"][0]["id"], "photos_version": page["photos_version"]}
        order = self.post("/orders", self.buyer, body, **{"Idempotency-Key": "v1"}).json()
        details = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["listing_details"]
        self.assertEqual(details["video"], video["url"])
        self.assertEqual(page["status"], "published")  # nothing to check again: no words in it

    def test_a_phone_held_upright_keeps_its_shape(self):
        lid = self.publish()["id"]
        self.send(lid, clip(2.5, "1080x1920"))
        info = probe(self.app.state.storage.read(self.page(lid)["video"]["url"]))
        self.assertEqual([(s["width"], s["height"]) for s in info["streams"] if s["codec_name"] == "h264"],
                         [(720, 1280)])

    def test_too_long_too_short_or_not_a_video_is_refused_and_nothing_changes(self):
        lid = self.publish()["id"]
        r = self.send(lid, clip(63, "320x240", 5))
        self.assertEqual((r.status_code, r.json()["code"]), (422, "video_too_long"))
        r = self.send(lid, clip(1, "320x240"))
        self.assertEqual((r.status_code, r.json()["code"]), (422, "video_too_short"))
        r = self.send(lid, b"\xff\xd8\xff" + b"0" * 5000, name="p.jpg")
        self.assertEqual((r.status_code, r.json()["code"]), (415, "video_unreadable"))
        self.assertIsNone(self.page(lid)["video"])

    def test_only_the_seller_adds_or_takes_it_off(self):
        lid = self.publish()["id"]
        self.assertEqual(self.send(lid, clip(2.5, "320x240"), token=self.buyer).status_code, 404)
        self.send(lid, clip(2.5, "320x240"))
        self.assertEqual(self.c.delete(f"/api/v1/listings/{lid}/video", headers=self.h(self.buyer)).status_code, 404)
        r = self.c.delete(f"/api/v1/listings/{lid}/video", headers=self.h(self.seller))
        self.assertEqual((r.status_code, r.json()["video"]), (200, None))
        self.assertIsNone(self.page(lid)["video"])

    def test_a_video_sent_again_or_taken_off_while_being_made_wins_over_the_old_one(self):
        lid = self.publish()["id"]
        started = now_utc()
        with self.db() as db:
            listing = db.get(Listing, lid)
            listing.video_state, listing.video_at = "processing", started
            db.commit()
        work = tempfile.mkdtemp()
        Path(work, "in").write_bytes(clip(2.5, "320x240"))
        # The seller sent another meanwhile: this one is dropped, and its upload deleted.
        self.assertFalse(video_routes.make_video(self.app.state, lid, started - timedelta(seconds=1), work))
        self.assertFalse(Path(work).exists())
        self.assertEqual(self.page(lid, self.seller)["video"]["state"], "processing")
        work = tempfile.mkdtemp()
        Path(work, "in").write_bytes(clip(2.5, "320x240"))
        self.assertTrue(video_routes.make_video(self.app.state, lid, started, work))
        self.assertEqual(self.page(lid)["video"]["state"], "ready")

    def test_a_video_lost_with_a_restart_shows_failed_to_its_seller_and_nothing_to_buyers(self):
        lid = self.publish()["id"]
        with self.db() as db:
            listing = db.get(Listing, lid)
            listing.video_state, listing.video_at = "processing", now_utc() - timedelta(hours=1)
            db.commit()
        self.assertEqual(self.page(lid, self.seller)["video"]["state"], "failed")
        self.assertIsNone(self.page(lid, self.buyer)["video"])

    def test_only_this_address_takes_a_large_body(self):
        lid = self.publish()["id"]
        big = b"\x00" * (13 * 1024 * 1024)
        r = self.send(lid, big)
        self.assertEqual((r.status_code, r.json()["code"]), (415, "video_unreadable"))  # past the size guard
        r = self.c.post("/api/v1/media", files={"file": ("p.jpg", big, "image/jpeg")}, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 413)

    def test_no_temporary_files_are_left(self):
        before = set(Path(tempfile.gettempdir()).glob("vitrina-video-*"))
        lid = self.publish()["id"]
        self.send(lid, clip(2.5, "320x240"))
        self.send(lid, clip(1, "320x240"))  # refused
        self.assertEqual(set(Path(tempfile.gettempdir()).glob("vitrina-video-*")), before)


    def test_a_playlist_or_concat_file_never_opens_other_files(self):
        lid = self.publish()["id"]
        # A real video elsewhere on the server, named by a playlist the seller sends: never read.
        with tempfile.TemporaryDirectory() as tmp:
            other = Path(tmp) / "other.ts"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "-", "-c", "copy", "-f", "mpegts", str(other)],
                           input=clip(2.5, "320x240"), check=True)
            for text in (f"#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.5,\n{other}\n#EXT-X-ENDLIST\n",
                         f"ffconcat version 1.0\nfile '{other}'\n"):
                r = self.send(lid, text.encode(), name="v.m3u8")
                self.assertEqual((r.status_code, r.json()["code"]), (415, "video_unreadable"))
        self.assertIsNone(self.page(lid)["video"])

    def test_too_large_hidden_or_a_full_line_is_refused_and_nothing_is_left(self):
        from unittest import mock
        from vitrina_api import video
        before = set(Path(tempfile.gettempdir()).glob("vitrina-video-*"))
        lid = self.publish()["id"]
        with mock.patch.object(video_routes, "VIDEO_UPLOAD_BYTES", 1000):
            r = self.send(lid, clip(2.5, "320x240"))
        self.assertEqual((r.status_code, r.json()["code"]), (413, "video_too_large"))
        # The line for the encoder is full: asked again later, nothing taken in.
        taken = [video.queue_places.acquire(blocking=False) for _ in range(video.VIDEO_QUEUE)]
        try:
            r = self.send(lid, clip(2.5, "320x240"))
            self.assertEqual((r.status_code, r.json()["code"]), (503, "video_unavailable"))
        finally:
            for t in taken:
                if t:
                    video.queue_places.release()
        with self.db() as db:
            db.get(Listing, lid).status = "hidden"
            db.commit()
        self.assertEqual(self.send(lid, clip(2.5, "320x240")).status_code, 409)
        self.assertEqual(self.c.delete(f"/api/v1/listings/{lid}/video", headers=self.h(self.seller)).status_code, 409)
        self.assertEqual(set(Path(tempfile.gettempdir()).glob("vitrina-video-*")), before)
        # Every place in the line is free again, refused or made.
        places = [video.queue_places.acquire(blocking=False) for _ in range(video.VIDEO_QUEUE)]
        for _ in places:
            video.queue_places.release()
        self.assertTrue(all(places))

    def test_a_job_that_waited_past_the_failed_notice_stays_failed(self):
        lid = self.publish()["id"]
        started = now_utc() - timedelta(hours=1)
        with self.db() as db:
            listing = db.get(Listing, lid)
            listing.video_state, listing.video_at = "processing", started
            db.commit()
        work = tempfile.mkdtemp()
        Path(work, "in").write_bytes(clip(2.5, "320x240"))
        self.assertFalse(video_routes.make_video(self.app.state, lid, started, work))
        self.assertEqual(self.page(lid, self.seller)["video"]["state"], "failed")
        self.assertIsNone(self.page(lid, self.buyer)["video"])


if __name__ == "__main__":
    unittest.main()
