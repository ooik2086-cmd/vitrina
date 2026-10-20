"""Background removal may only change transparency, never the product's colours or outline."""
import contextlib
import io
import json
import logging
import os
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

from tests.test_api import LISTING, MediaTests, jpeg
from vitrina_api.cutout import backdrop_for, closest_frame, cut_out, fill_holes, make_thumb, process_photo


def solid(colour, size=(800, 600)) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", size, colour).save(out, "JPEG")
    return out.getvalue()


def ring_mask(size=(400, 400)):
    """A product with a 'hole' the model mistook for background: a stripe inside the outline."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rectangle((100, 100, 300, 300), fill=255)
    d.rectangle((180, 150, 220, 250), fill=0)
    return m


def center_segmenter(img):
    m = Image.new("L", img.size, 0)
    w, h = img.size
    ImageDraw.Draw(m).ellipse((w // 4, h // 4, 3 * w // 4, 3 * h // 4), fill=255)
    return m


class CutoutUnitTests(unittest.TestCase):
    def test_rgb_is_copied_exactly_and_only_alpha_is_added(self):
        img = Image.effect_noise((400, 400), 60).convert("RGB")
        out = cut_out(img, ring_mask())
        self.assertEqual(out.mode, "RGBA")
        self.assertEqual(list(out.convert("RGB").getdata()), list(img.getdata()))

    def test_holes_inside_the_outline_are_filled_but_real_background_stays_clear(self):
        alpha = fill_holes(ring_mask())
        self.assertEqual(alpha.getpixel((200, 200)), 255)  # the stripe is part of the shoe
        self.assertEqual(alpha.getpixel((20, 20)), 0)      # the backdrop is gone

    def test_implausible_masks_keep_the_original(self):
        data = jpeg()
        self.assertIsNone(process_photo(data, lambda img: Image.new("L", img.size, 0)))
        self.assertIsNone(process_photo(data, lambda img: Image.new("L", img.size, 255)))
        out = Image.open(io.BytesIO(process_photo(data, center_segmenter)))
        self.assertEqual((out.format, out.mode), ("WEBP", "RGBA"))


def wedge(direction: str, size=(480, 360), box=(80, 80, 400, 280), haze=False) -> bytes:
    """A cut-out "shoe": a wedge on a transparent canvas, its point to the left or right; with haze, the nearly
    clear specks a segmenter leaves in the corners."""
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    points = [(x0, (y0 + y1) // 2), (x1, y0), (x1, y1)] if direction == "left" else [(x1, (y0 + y1) // 2),
                                                                                       (x0, y0), (x0, y1)]
    ImageDraw.Draw(img).polygon(points, fill=(60, 60, 70, 255))
    if haze:
        img.putpixel((0, 0), (60, 60, 70, 3))
        img.putpixel((size[0] - 1, size[1] - 1), (60, 60, 70, 3))
    out = io.BytesIO()
    img.save(out, "PNG")
    return out.getvalue()


class CoverFrameUnitTests(unittest.TestCase):
    def test_the_frame_with_the_cover_angle_is_found_whatever_its_size_in_the_photo(self):
        cover = wedge("right")
        frames = [wedge("left"), b"not an image", wedge("right", box=(200, 150, 360, 250)), wedge("left")]
        self.assertEqual(closest_frame(cover, frames), 2)
        self.assertIsNone(closest_frame(cover, [b"broken"]))

    def test_faint_specks_at_the_edges_do_not_change_the_shoe_box(self):
        cover = wedge("right")
        # A small shoe in a corner: only the crop to the shoe makes it look like the cover; the decoy points the
        # other way but sits where the cover's shoe sits.
        frames = [wedge("left", box=(90, 90, 390, 270)), wedge("right", box=(300, 220, 460, 340), haze=True)]
        self.assertEqual(closest_frame(cover, frames), 1)


class CutoutApiTests(MediaTests):
    def setUp(self):
        super().setUp()
        self.app.state.segmenter = center_segmenter

    def mine(self, listing_id):
        items = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"]
        return next(i for i in items if i["id"] == listing_id)

    def test_new_listing_gets_cutouts_except_labels_and_defects(self):
        urls = [self.upload(self.seller, jpeg()).json()["url"] for _ in range(6)]
        angles = ("front", "outer", "inner", "back", "label", "defect")
        photos = [{"url": u, "angle": a} for u, a in zip(urls, angles)]
        r = self.post("/listings", self.seller, {**LISTING, "condition": "defective", "defects": "Сызат",
                                                 "photos": photos})
        self.assertEqual(r.status_code, 201, r.text)
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]
        processed = {m["angle"]: m["processed_url"] for m in mine["media"]}
        for angle in ("front", "outer", "inner", "back"):
            self.assertTrue(processed[angle].endswith(".webp"), angle)
        self.assertIsNone(processed["label"])
        self.assertIsNone(processed["defect"])
        served = self.c.get(processed["front"].replace("http://test", ""))
        self.assertEqual(served.status_code, 200)
        self.assertEqual(Image.open(io.BytesIO(served.content)).mode, "RGBA")

    def test_one_media_job_failing_does_not_stop_the_others(self):
        from vitrina_api import listing_routes
        real = listing_routes.cutout_listing, listing_routes.thumb_listing, listing_routes.embed_listing
        embedded = []

        def broken(state, lid):
            raise RuntimeError("storage went away")
        try:
            # The cut-outs fail: the small copies, from the photos as taken, and the search vector still come.
            listing_routes.cutout_listing = broken
            listing_routes.embed_listing = lambda state, lid: embedded.append(lid)
            with self.assertLogs("vitrina", level="ERROR") as logs:
                r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))})
            self.assertEqual(r.status_code, 201, r.text)
            self.assertIn("failed for listing", "\n".join(logs.output))
            media = self.mine(r.json()["id"])["media"]
            self.assertTrue(all(m["thumb_url"] and not m["processed_url"] for m in media), media)
            self.assertEqual(embedded, [r.json()["id"]])
            # The small copies fail: the search vector still comes.
            listing_routes.cutout_listing, listing_routes.thumb_listing = real[0], broken
            with self.assertLogs("vitrina", level="ERROR"):
                r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))})
            self.assertEqual(embedded[-1], r.json()["id"])
        finally:
            listing_routes.cutout_listing, listing_routes.thumb_listing, listing_routes.embed_listing = real

    def test_changed_photos_drop_the_old_search_vector(self):
        from vitrina_api import listing_routes
        from vitrina_api.models import ListingEmbedding
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
        with self.app.state.sessions() as db:
            db.add(ListingEmbedding(listing_id=lid, model="m", vector=b"old"))
            db.commit()
        real = listing_routes.embed_listing

        def broken(state, listing_id):
            raise RuntimeError("storage went away")
        listing_routes.embed_listing = broken
        self.addCleanup(setattr, listing_routes, "embed_listing", real)
        with self.assertLogs("vitrina", level="ERROR"):
            r = self.c.patch(f"/api/v1/listings/{lid}", json={"photos": self.four((30, 90, 160))},
                             headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        # Not found by the photo it no longer has; the backfill sees the vector missing.
        with self.app.state.sessions() as db:
            self.assertIsNone(db.get(ListingEmbedding, lid))
        # A change that leaves the photos keeps it.
        with self.app.state.sessions() as db:
            db.add(ListingEmbedding(listing_id=lid, model="m", vector=b"new"))
            db.commit()
        self.c.patch(f"/api/v1/listings/{lid}", json={"price_tiyn": 4_000_000}, headers=self.h(self.seller))
        with self.app.state.sessions() as db:
            self.assertIsNotNone(db.get(ListingEmbedding, lid))

    def test_the_backfill_makes_small_copies_when_the_cut_outs_fail(self):
        from vitrina_api.models import Media
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
        with self.app.state.sessions() as db:  # from before the cut-outs and the small copies
            for m in db.query(Media).filter(Media.listing_id == lid):
                m.processed_url = m.thumb_url = None
            db.commit()
        self.with_segmenter()
        from vitrina_api import photo_work
        real = photo_work.cutout_listing

        def broken(state, listing_id):
            raise RuntimeError("storage went away")
        broken.__name__ = "cutout_listing"
        photo_work.cutout_listing = broken
        self.addCleanup(setattr, photo_work, "cutout_listing", real)
        with self.assertLogs(level="ERROR"):
            code, out = self.backfill("--without-models")
        self.assertEqual(code, 1)
        self.assertIn(f"listing {lid}: failed in cutout_listing", out)
        self.assertTrue(all(m["thumb_url"] for m in self.mine(lid)["media"]))

    def no_shoe_in(self, *shades):
        """A segmenter that finds no shoe in the frames of these shades (as a real model may), and counts its calls."""
        calls = []

        def segment(img):
            calls.append(img.convert("RGB").getpixel((0, 0)))
            if calls[-1] in shades:
                return Image.new("L", img.size, 0)
            return center_segmenter(img)
        self.app.state.segmenter = segment
        return calls

    def stored(self):
        return sum(len(files) for _, _, files in os.walk(self.cfg.media_dir))

    def test_a_turn_with_a_frame_that_cannot_be_cut_out_is_kept_as_taken_with_small_copies_to_match(self):
        from vitrina_api.listing_routes import cutout_listing, thumb_listing
        from vitrina_api.models import Listing
        from vitrina_api.share import turn_shots
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        calls = self.no_shoe_in(shades[3])
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((200, 40, 40))
                                                   + self.frames(shades)}).json()["id"]
        self.assertEqual(calls.count(shades[3]), 1)
        self.assertNotIn(shades[4], calls)  # the turn is given up at its first frame with no shoe
        media = self.mine(lid)["media"]
        frames = [m for m in media if m["angle"] == "frame"]
        # The turn is shown as taken (as the app and the shared page would anyway), with small copies of those
        # photos to turn through; the side photos keep their cut-outs.
        self.assertTrue(all(m["processed_url"] is None and m["thumb_url"] for m in frames), frames)
        with self.app.state.sessions() as db:
            row = db.get(Listing, lid)
            shots, cut = turn_shots(row, row.media)
        self.assertFalse(cut)
        self.assertTrue(all(small != full for small, full in shots))  # light: small copies, not full photos
        self.assertTrue(all(m["processed_url"] for m in media if m["angle"] in ("front", "outer", "inner", "back")))
        # The seller is told which frame to take again; a buyer is not.
        self.assertEqual([m["no_shoe"] for m in frames], [i == 3 for i in range(8)])
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).status_code, 200)
        for who in ({}, self.h(self.buyer)):
            public = self.c.get(f"/api/v1/listings/{lid}", headers=who).json()["media"]
            self.assertTrue(all("no_shoe" not in m for m in public))
        # The seller hears it once, and the note opens the listing's own page.
        notes = [n for n in self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
                 if n["kind"] == "photo_no_shoe"]
        self.assertEqual([(n["listing_id"], n["text"].split(":")[0]) for n in notes], [(lid, f"«{LISTING['title']}»")])
        self.assertIn("360°", notes[0]["text"])  # a frame: the turn is taken again, not one photo
        # Later runs (the backfill) know the turn cannot be cut out: no model time, no files thrown away.
        calls.clear()
        files = self.stored()
        self.assertEqual((cutout_listing(self.app.state, lid), thumb_listing(self.app.state, lid)), (0, 0))
        self.assertEqual((calls, self.stored()), ([], files))
        notes = self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
        self.assertEqual(sum(n["kind"] == "photo_no_shoe" for n in notes), 1)

    def test_no_note_about_a_photo_on_a_listing_the_seller_is_done_with(self):
        from vitrina_api.listing_routes import cutout_listing
        from vitrina_api.models import Listing, User
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        self.app.state.segmenter = None  # a listing from before the model, as the backfill finds it
        sold = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        gone = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        with self.app.state.sessions() as db:
            db.get(Listing, sold).status = "sold"
            db.commit()
        self.no_shoe_in(shades[3])
        cutout_listing(self.app.state, sold)
        notes = lambda: [n for n in self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
                         if n["kind"] == "photo_no_shoe"]  # noqa: E731
        self.assertEqual(notes(), [])
        self.assertTrue(any(m["no_shoe"] for m in self.mine(sold)["media"]))  # still marked for the page
        with self.app.state.sessions() as db:  # the seller deleted the account: nobody to tell
            user = db.get(User, db.get(Listing, gone).seller_id)
            user.deleted_at = user.created_at
            db.commit()
        cutout_listing(self.app.state, gone)
        with self.app.state.sessions() as db:
            from vitrina_api.models import Notification
            self.assertEqual(db.query(Notification).filter(Notification.kind == "photo_no_shoe").count(), 0)

    def test_a_scan_keeps_the_cut_outs_of_the_parts_whose_frames_were_all_cut_out(self):
        from vitrina_api.models import Listing
        from vitrina_api.share import turn_shots
        shades = [(20 + 18 * i,) * 3 for i in range(12)]
        self.no_shoe_in(shades[10])  # straight under the sole
        frames = self.frames(shades)
        stops = [{"url": frames[8]["url"], "angle": "top"}, {"url": frames[10]["url"], "angle": "sole"}]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((200, 40, 40)) + frames + stops}
                        ).json()["id"]
        media = [m for m in self.mine(lid)["media"] if m["angle"] == "frame"]
        self.assertTrue(all(m["processed_url"] for m in media[:10]), media)  # the turn and the top
        self.assertTrue(all(m["processed_url"] is None and m["thumb_url"] for m in media[10:]), media)  # the sole
        with self.app.state.sessions() as db:
            row = db.get(Listing, lid)
            self.assertTrue(turn_shots(row, row.media)[1])
        # The sole is a frame and a stop photo: one picture, one note to the seller.
        notes = self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
        self.assertEqual(sum(n["kind"] == "photo_no_shoe" for n in notes), 1)

    def test_a_turn_that_failed_for_a_while_is_cut_out_on_the_next_run(self):
        from vitrina_api.listing_routes import cutout_listing
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        away = []

        def segment(img):  # the storage or the model fails once, half way round
            if img.convert("RGB").getpixel((0, 0)) == shades[3] and not away:
                away.append(1)
                raise RuntimeError("away")
            return center_segmenter(img)
        self.app.state.segmenter = segment
        with self.assertLogs("vitrina", level="ERROR"):
            lid = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        self.assertTrue(all(m["processed_url"] is None for m in self.mine(lid)["media"]))
        self.assertEqual(cutout_listing(self.app.state, lid), 8)
        self.assertTrue(all(m["processed_url"] for m in self.mine(lid)["media"]))

    def test_a_turn_left_half_cut_out_is_shown_as_taken(self):
        from vitrina_api.listing_routes import cutout_listing
        from sqlalchemy import select
        from vitrina_api.models import Media
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        with self.app.state.sessions() as db:  # cut out by an older version, but for one frame
            row = db.scalars(select(Media).where(Media.listing_id == lid).order_by(Media.position)).all()[3]
            row.processed_url, row.no_cutout = None, "segmenter"
            db.commit()
        with self.assertLogs("vitrina", level="INFO") as logs:
            self.assertEqual(cutout_listing(self.app.state, lid), 0)
        self.assertIn("1 of 8 frames", "\n".join(logs.output))
        self.assertTrue(all(m["processed_url"] is None for m in self.mine(lid)["media"]))

    def test_a_turn_the_seller_changes_meanwhile_is_left_to_the_job_for_the_new_photos(self):
        from vitrina_api import cutout
        from vitrina_api.listing_routes import cutout_listing
        from vitrina_api.models import Listing, Media
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        self.app.state.segmenter = None
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        self.app.state.segmenter = center_segmenter
        real = cutout.process_photo

        def meanwhile(*args):  # the seller adds a frame while this job cuts the turn out
            cutout.process_photo = real
            with self.app.state.sessions() as db:
                url = self.frames(shades[:1])[0]["url"]
                row = db.get(Listing, lid)
                row.media.append(Media(original_url=url, angle="frame", position=9))
                db.commit()
            return real(*args)
        cutout.process_photo = meanwhile
        try:
            with self.assertNoLogs("vitrina", level="ERROR"):
                self.assertEqual(cutout_listing(self.app.state, lid), 0)
        finally:
            cutout.process_photo = real
        self.assertTrue(all(m["processed_url"] is None for m in self.mine(lid)["media"]))
        self.assertEqual(cutout_listing(self.app.state, lid), 9)  # what the job for the new photos does

    def test_without_a_model_photos_stay_original(self):
        self.app.state.segmenter = None
        url = self.upload(self.seller, jpeg()).json()["url"]
        photos = [{"url": url, "angle": a} for a in ("front", "outer", "inner", "back")]
        self.post("/listings", self.seller, {**LISTING, "photos": photos})
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]
        self.assertTrue(all(m["processed_url"] is None for m in mine["media"]))

    def test_every_photo_gets_a_small_copy_that_keeps_the_cut_out(self):
        urls = [self.upload(self.seller, jpeg()).json()["url"] for _ in range(5)]
        photos = [{"url": u, "angle": a} for u, a in zip(urls, ("front", "outer", "inner", "back", "label"))]
        self.post("/listings", self.seller, {**LISTING, "photos": photos})
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]
        for m in mine["media"]:
            img = Image.open(io.BytesIO(self.c.get(m["thumb_url"].replace("http://test", "")).content))
            self.assertEqual(img.format, "WEBP")
            self.assertLessEqual(max(img.size), 480)
            self.assertEqual(img.mode, "RGB" if m["angle"] == "label" else "RGBA", m["angle"])

    def test_a_dark_shoe_gets_a_light_backdrop_and_a_light_shoe_a_dark_one(self):
        for colour, want in (((25, 25, 30), "light"), ((235, 235, 225), "dark")):
            url = self.upload(self.seller, solid(colour)).json()["url"]
            photos = [{"url": url, "angle": a} for a in ("front", "outer", "inner", "back")]
            r = self.post("/listings", self.seller, {**LISTING, "photos": photos})
            self.assertEqual(self.mine(r.json()["id"])["backdrop"], want)

    def test_without_a_model_there_are_small_copies_but_no_backdrop(self):
        self.app.state.segmenter = None
        url = self.upload(self.seller, jpeg()).json()["url"]
        photos = [{"url": url, "angle": a} for a in ("front", "outer", "inner", "back")]
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos})
        got = self.mine(r.json()["id"])
        self.assertIsNone(got["backdrop"])
        self.assertTrue(all(m["thumb_url"] for m in got["media"]))

    def test_close_ups_keep_more_pixels_than_showcase_photos(self):
        big = solid((120, 90, 60), (3600, 2400))
        for detail, side in ((False, 2000), (True, 3000)):
            r = self.c.post(f"/api/v1/media?detail={'true' if detail else 'false'}", headers=self.h(self.seller),
                            files={"file": ("p.jpg", big, "image/jpeg")})
            img = Image.open(io.BytesIO(self.c.get(r.json()["url"].replace("http://test", "")).content))
            self.assertEqual(max(img.size), side)


    def four(self, colour):
        url = self.upload(self.seller, solid(colour)).json()["url"]
        return [{"url": url, "angle": a} for a in ("front", "outer", "inner", "back")]

    def test_the_backdrop_follows_the_turning_frames_before_the_front(self):
        frame = self.upload(self.seller, solid((235, 235, 225))).json()["url"]
        frames = [{"url": frame, "angle": "frame"}] * 8
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((25, 25, 30)) + frames})
        self.assertEqual(self.mine(r.json()["id"])["backdrop"], "dark")  # the light frames decide

    def test_new_photos_bring_a_new_backdrop(self):
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((25, 25, 30))})
        lid = r.json()["id"]
        self.assertEqual(self.mine(lid)["backdrop"], "light")
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller),
                         json={"photos": self.four((235, 235, 225))})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.mine(lid)["backdrop"], "dark")

    def test_a_close_up_photo_stays_as_taken_but_is_kept_large(self):
        url = self.c.post("/api/v1/media?detail=true", headers=self.h(self.seller),
                          files={"file": ("d.jpg", solid((120, 90, 60), (3600, 2400)), "image/jpeg")}).json()["url"]
        photos = self.four((120, 90, 60)) + [{"url": url, "angle": "detail"}]
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos})
        self.assertEqual(r.status_code, 201, r.text)
        detail = next(m for m in self.mine(r.json()["id"])["media"] if m["angle"] == "detail")
        self.assertIsNone(detail["processed_url"])  # nothing around it to remove
        self.assertTrue(detail["thumb_url"])
        img = Image.open(io.BytesIO(self.c.get(detail["original_url"].replace("http://test", "")).content))
        self.assertEqual(max(img.size), 3000)

    def test_a_cut_out_made_later_replaces_the_small_copy(self):
        from vitrina_api.listing_routes import cutout_listing, thumb_listing
        self.app.state.segmenter = None
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))})
        lid = r.json()["id"]
        before = {m["angle"]: m["thumb_url"] for m in self.mine(lid)["media"]}
        self.app.state.segmenter = center_segmenter  # the model arrives, as the backfill script would see it
        cutout_listing(self.app.state, lid)
        thumb_listing(self.app.state, lid)
        for m in self.mine(lid)["media"]:
            self.assertNotEqual(m["thumb_url"], before[m["angle"]])
            img = Image.open(io.BytesIO(self.c.get(m["thumb_url"].replace("http://test", "")).content))
            self.assertEqual(img.mode, "RGBA")
        self.assertIsNotNone(self.mine(lid)["backdrop"])

    def test_the_backfill_uses_the_storage_the_api_uses(self):
        from scripts import cutout_backfill
        used = []
        real = (cutout_backfill.Settings, cutout_backfill.make_storage)

        def storage(cfg):
            used.append(cfg)
            return self.app.state.storage
        cutout_backfill.Settings, cutout_backfill.make_storage = (lambda: self.cfg), storage
        try:
            self.app.state.segmenter = None
            r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))})
            from vitrina_api.models import Media
            with self.app.state.sessions() as db:  # a listing from before the small copies existed
                for m in db.query(Media).all():
                    m.thumb_url = None
                db.commit()
            cutout_backfill.main(["--without-models"])
        finally:
            cutout_backfill.Settings, cutout_backfill.make_storage = real
        self.assertEqual(used, [self.cfg])
        self.assertTrue(all(m["thumb_url"] for m in self.mine(r.json()["id"])["media"]))

    def frames(self, colours):
        return [{"url": self.upload(self.seller, solid(c)).json()["url"], "angle": "frame"} for c in colours]

    def test_the_turn_starts_at_the_frame_that_looks_like_the_cover_unless_the_seller_chose_one(self):
        shades = [(20 + 25 * i, 20 + 25 * i, 20 + 25 * i) for i in range(8)]
        frames = self.frames(shades)
        cover = self.four(shades[5])  # the cover looks like the sixth frame
        r = self.post("/listings", self.seller, {**LISTING, "photos": cover + frames})
        lid = r.json()["id"]
        self.assertEqual(self.mine(lid)["cover_frame"], frames[5]["url"])
        # The seller's own choice stays when the media job runs again.
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller), json={"cover_frame": frames[2]["url"]})
        self.assertEqual((r.status_code, r.json()["cover_frame"]), (200, frames[2]["url"]))
        from vitrina_api.listing_routes import thumb_listing
        thumb_listing(self.app.state, lid)
        self.assertEqual(self.mine(lid)["cover_frame"], frames[2]["url"])
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller), json={"cover_frame": cover[0]["url"]})
        self.assertEqual((r.status_code, r.json()["code"]), (422, "validation"))  # not a frame
        # A new cover voids the choice; the match is made again for it.
        new_cover = self.four(shades[1])
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller), json={"photos": new_cover + frames})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.mine(lid)["cover_frame"], frames[1]["url"])

    def test_each_side_photo_is_matched_to_its_frame_and_a_new_photo_voids_it(self):
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        frames = self.frames(shades)
        side, front = (self.upload(self.seller, solid(shades[k])).json()["url"] for k in (5, 2))
        photos = [{"url": side, "angle": "outer"}, {"url": front, "angle": "front"}]
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos + frames})
        lid = r.json()["id"]
        mine = self.mine(lid)
        self.assertEqual(mine["cover_frame"], frames[5]["url"])
        self.assertEqual(mine["angle_frames"], {"outer": frames[5]["url"], "front": frames[2]["url"]})
        # A seller's cover frame does not move the sides; a new front photo is matched again.
        self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller), json={"cover_frame": frames[4]["url"]})
        self.assertEqual(self.mine(lid)["angle_frames"]["front"], frames[2]["url"])
        new_front = self.upload(self.seller, solid(shades[6])).json()["url"]
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller),
                         json={"photos": [photos[0], {"url": new_front, "angle": "front"}] + frames})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.mine(lid)["angle_frames"], {"outer": frames[5]["url"], "front": frames[6]["url"]})
        # Without the front photo there is no front frame, even though one was stored.
        r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller), json={"photos": photos[:1] + frames})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.mine(lid)["angle_frames"], {"outer": frames[5]["url"]})

    def test_a_match_that_ran_on_old_photos_keeps_what_changed_meanwhile(self):
        from vitrina_api import cutout
        from vitrina_api.models import Listing, Media
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        frames = self.frames(shades)
        side, front = (self.upload(self.seller, solid(shades[k])).json()["url"] for k in (5, 2))
        photos = [{"url": side, "angle": "outer"}, {"url": front, "angle": "front"}]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": photos + frames}).json()["id"]
        new_outer, new_front = (self.upload(self.seller, solid(shades[k])).json()["url"] for k in (4, 6))
        real = cutout.side_frames

        def meanwhile(*args):  # while the outer side is compared, the front is replaced and matched by another job
            out = real(*args)
            with self.app.state.sessions() as db:
                row = db.get(Listing, lid)
                old = next(m for m in row.media if m.angle == "front")
                fresh = Media(original_url=new_front, processed_url=old.processed_url, thumb_url=old.thumb_url,
                              angle="front", position=old.position)
                row.media.remove(old)
                row.media.append(fresh)
                marks = json.loads(row.angle_frames)
                marks["front"] = {"frame": frames[6]["url"], "of": new_front}
                row.angle_frames = json.dumps(marks)
                db.commit()
            return out
        cutout.side_frames = meanwhile
        try:
            r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller),
                             json={"photos": [{"url": new_outer, "angle": "outer"}, photos[1]] + frames})
        finally:
            cutout.side_frames = real
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.mine(lid)["angle_frames"], {"outer": frames[4]["url"], "front": frames[6]["url"]})

    def test_a_cover_frame_found_on_old_photos_gives_way_to_what_changed_meanwhile(self):
        from vitrina_api import cutout
        from vitrina_api.models import Listing
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        frames = self.frames(shades)
        side = self.upload(self.seller, solid(shades[5])).json()["url"]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": [{"url": side, "angle": "outer"}] + frames}
                        ).json()["id"]
        real = cutout.closest_frame

        def run(change):  # a new cover is compared while something else changes the listing
            def meanwhile(*args):
                out = real(*args)
                with self.app.state.sessions() as db:
                    change(db.get(Listing, lid))
                    db.commit()
                return out
            cover = self.upload(self.seller, solid(shades[4])).json()["url"]
            cutout.closest_frame = meanwhile
            try:
                r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller),
                                 json={"photos": [{"url": cover, "angle": "outer"}] + frames})
            finally:
                cutout.closest_frame = real
            self.assertEqual(r.status_code, 200, r.text)
            with self.app.state.sessions() as db:
                row = db.get(Listing, lid)
                return row.cover_frame, row.cover_frame_of, next(m for m in row.media if m.angle == "outer")

        def seller_picks(row):
            row.cover_frame = frames[1]["url"]
            row.cover_frame_of = next(m for m in row.media if m.angle == "outer").original_url
        frame, of, cover = run(seller_picks)
        self.assertEqual((frame, of), (frames[1]["url"], cover.original_url))  # the seller's choice wins

        def replaced(row):
            row.cover_frame = row.cover_frame_of = None
            next(m for m in row.media if m.angle == "outer").original_url = "http://test/media/elsewhere.jpg"
        frame, of, cover = run(replaced)
        self.assertEqual((frame, of), (None, None))  # nothing is written for a photo that is gone

    def test_a_photo_deleted_while_the_media_jobs_run_does_not_stop_them(self):
        from vitrina_api import cutout
        from vitrina_api.models import Listing
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        frames = self.frames(shades)
        side = self.upload(self.seller, solid(shades[5])).json()["url"]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": [{"url": side, "angle": "outer"}] + frames}
                        ).json()["id"]
        for job in ("process_photo", "make_thumb"):
            with self.subTest(job=job):
                real = getattr(cutout, job)
                deleted = []

                def meanwhile(*args, real=real, deleted=deleted):  # the seller drops the new photo mid-job
                    out = real(*args)
                    if not deleted:
                        with self.app.state.sessions() as db:
                            row = db.get(Listing, lid)
                            gone = next(m for m in row.media if m.angle == "inner")
                            deleted.append(gone.original_url)
                            row.media.remove(gone)
                            db.commit()
                    return out
                new = self.upload(self.seller, solid(shades[3])).json()["url"]
                with self.app.state.sessions() as db:  # so this job has every photo's small copy to make
                    row = db.get(Listing, lid)
                    for m in row.media:
                        m.thumb_url = None
                    row.backdrop = None
                    db.commit()
                setattr(cutout, job, meanwhile)
                try:
                    r = self.c.patch(f"/api/v1/listings/{lid}", headers=self.h(self.seller),
                                     json={"photos": [{"url": side, "angle": "outer"}, {"url": new, "angle": "inner"}]
                                           + frames})
                finally:
                    setattr(cutout, job, real)
                self.assertEqual(r.status_code, 200, r.text)
                media = self.mine(lid)["media"]
                self.assertNotIn(deleted[0], [m["original_url"] for m in media])
                # The photos left got their cut-outs, small copies and backdrop from this job all the same.
                self.assertTrue(all(m["thumb_url"] for m in media), media)
                self.assertIsNotNone(self.mine(lid)["backdrop"])

    def test_a_photo_added_while_an_older_job_runs_gets_a_small_copy_of_its_cut_out(self):
        from vitrina_api import cutout
        from vitrina_api.listing_routes import cutout_listing, thumb_listing
        from vitrina_api.models import Listing, Media
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
        new = self.upload(self.seller, solid((30, 140, 200))).json()["url"]
        with self.app.state.sessions() as db:  # the seller's new photo, not cut out yet
            row = db.get(Listing, lid)
            row.media.append(Media(original_url=new, angle="top", position=9))
            db.commit()
        real = cutout.process_photo

        def meanwhile(*args):  # while this job cuts the new photo out, the older job makes its small copies
            cutout.process_photo = real
            thumb_listing(self.app.state, lid)
            return real(*args)
        cutout.process_photo = meanwhile
        try:
            self.assertEqual(cutout_listing(self.app.state, lid), 1)
        finally:
            cutout.process_photo = real
        thumb_listing(self.app.state, lid)
        top = next(m for m in self.mine(lid)["media"] if m["original_url"] == new)
        img = Image.open(io.BytesIO(self.c.get(top["thumb_url"].replace("http://test", "")).content))
        self.assertEqual(img.mode, "RGBA")  # made from the cut-out, not from the photo as taken

    def test_a_side_is_snapped_to_where_the_shoe_is_square_on(self):
        from vitrina_api import cutout

        def shoe(k, width):  # a cut-out shoe as wide as the angle shows it, shaded by the angle, on a clear canvas
            img = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
            img.paste((40 + 6 * k, 60, 40, 255), (100 - width // 2, 60, 100 + width // 2, 140))
            out = io.BytesIO()
            img.save(out, "PNG")
            return out.getvalue()
        widths = [180 - int(140 * abs(__import__("math").sin(k * __import__("math").pi / 16))) for k in range(32)]
        turn = [shoe(k, w) for k, w in enumerate(widths)]  # side on at 0 and 16, toe or heel on at 8 and 24
        # A three-quarter front photo looks most like frame 5; the toe is square on at frame 8.
        found = cutout.side_frames({"front": turn[5], "outer": turn[2]}, turn)
        self.assertEqual(found, {"front": 8, "outer": 0})

    def test_without_frames_there_is_no_cover_frame(self):
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))})
        self.assertIsNone(self.mine(r.json()["id"])["cover_frame"])

    def test_photos_that_are_not_cut_out_or_a_cover_off_the_turn_are_not_matched(self):
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        self.app.state.segmenter = None  # the backdrops would be compared, not the shoe
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four(shades[5]) + self.frames(shades)})
        self.assertIsNone(self.mine(r.json()["id"])["cover_frame"])
        self.app.state.segmenter = center_segmenter
        sole = [{**p, "angle": "sole"} for p in self.four(shades[5])[:1]]  # a sole is no angle of the turn
        r = self.post("/listings", self.seller, {**LISTING, "photos": sole + self.four(shades[5]) + self.frames(shades)})
        self.assertIsNone(self.mine(r.json()["id"])["cover_frame"])

    def test_the_backfill_matches_listings_made_before_the_match(self):
        from scripts import cutout_backfill
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        frames = self.frames(shades)
        r = self.post("/listings", self.seller, {**LISTING, "photos": self.four(shades[3]) + frames})
        from vitrina_api.models import Listing
        with self.app.state.sessions() as db:
            row = db.get(Listing, r.json()["id"])
            row.cover_frame = row.angle_frames = None
            db.commit()
        real = cutout_backfill.Settings, cutout_backfill.make_storage
        cutout_backfill.Settings, cutout_backfill.make_storage = (lambda: self.cfg), (lambda cfg: self.app.state.storage)
        try:
            cutout_backfill.main(["--without-models"])
        finally:
            cutout_backfill.Settings, cutout_backfill.make_storage = real
        self.assertEqual(self.mine(r.json()["id"])["cover_frame"], frames[3]["url"])
        self.assertEqual(self.mine(r.json()["id"])["angle_frames"]["front"], frames[3]["url"])

    def backfill(self, *args, thumbs=None):
        """Runs the backfill script on the test database and storage; thumbs stands in for its thumb job."""
        from scripts import cutout_backfill
        from vitrina_api import photo_work
        real = cutout_backfill.Settings, cutout_backfill.make_storage, photo_work.thumb_listing
        cutout_backfill.Settings, cutout_backfill.make_storage = (lambda: self.cfg), (lambda cfg: self.app.state.storage)
        photo_work.thumb_listing = thumbs or real[2]
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as stop:
                cutout_backfill.main(list(args))
                raise SystemExit(0)
        finally:
            cutout_backfill.Settings, cutout_backfill.make_storage, photo_work.thumb_listing = real
        return stop.exception.code, out.getvalue()

    def test_the_backfill_carries_on_past_a_listing_that_fails_and_says_so(self):
        from vitrina_api.listing_routes import thumb_listing
        from vitrina_api.models import Listing
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        ids = [self.post("/listings", self.seller, {**LISTING, "photos": self.four(shades[3]) + self.frames(shades)}
                         ).json()["id"] for _ in range(3)]
        with self.app.state.sessions() as db:
            for lid in ids:
                db.get(Listing, lid).cover_frame = None
            db.commit()

        def thumbs(state, lid):
            if lid == ids[0]:
                raise RuntimeError("storage went away")
            if lid == ids[1]:  # one photo's error is logged and the job carries on: still a failure here
                logging.getLogger("vitrina_api.listing_routes").error("thumbnail failed for one photo")
            return thumb_listing(state, lid)
        from vitrina_api.listing_routes import embed_listing
        embedded = []

        def embed(state, lid):
            embedded.append(lid)
            return embed_listing(state, lid)
        from vitrina_api import photo_work
        photo_work.embed_listing = embed
        self.addCleanup(setattr, photo_work, "embed_listing", embed_listing)
        self.with_embedder()
        with self.assertLogs(level="ERROR"):
            code, out = self.backfill("--without-models", thumbs=thumbs)
        self.assertEqual(code, 1)
        self.assertIn(f"1 of 3 listings done; failed: {ids[0]}, {ids[1]}", out)
        self.assertEqual(embedded, ids)  # the failed small copies did not keep the search vector from being made
        self.assertIsNone(self.mine(ids[0])["cover_frame"])
        self.assertIsNotNone(self.mine(ids[2])["cover_frame"])  # the next listing was still done

    def with_embedder(self):
        """The backfill gets a search model, as it would have with VITRINA_SEARCH_MODEL set."""
        import numpy
        from scripts import cutout_backfill
        real = cutout_backfill.visual.load_embedder
        cutout_backfill.visual.load_embedder = lambda path: (lambda data: numpy.ones(4, numpy.float32))
        self.addCleanup(setattr, cutout_backfill.visual, "load_embedder", real)

    def worker(self):
        """The API leaves photo work to a photo worker, here on the test database and storage with a clock the
        test moves."""
        from vitrina_api.photo_work import Worker
        self.cfg.photo_work = "worker"
        self.now = [1000.0]
        return Worker(self.app.state, clock=lambda: self.now[0])

    def test_with_a_photo_worker_the_api_leaves_the_work_to_it_in_the_order_given(self):
        work = self.worker()
        first = self.four((120, 90, 60))
        old = self.post("/listings", self.seller, {**LISTING, "photos": first}).json()["id"]
        new = self.post("/listings", self.seller, {**LISTING, "photos": self.four((60, 90, 120))}).json()["id"]
        self.assertEqual([m["processed_url"] or m["thumb_url"] for m in self.mine(new)["media"]], [None] * 4)
        self.assertEqual(work.step(), old)  # sellers waiting are served in the order they came
        self.assertTrue(all(m["processed_url"] and m["thumb_url"] for m in self.mine(old)["media"]))
        self.assertIsNone(self.mine(new)["media"][0]["processed_url"])
        self.assertEqual(work.step(), new)
        self.assertTrue(all(m["processed_url"] and m["thumb_url"] for m in self.mine(new)["media"]))
        self.assertIsNone(work.step())  # nothing left: no photo is read again
        photos = self.four((200, 200, 40))  # new photos: due again, at once
        self.assertEqual(self.c.patch(f"/api/v1/listings/{old}", json={"photos": photos},
                                      headers=self.h(self.seller)).status_code, 200)
        self.assertEqual(work.step(), old)
        self.assertIsNone(work.step())
        self.assertEqual(self.c.patch(f"/api/v1/listings/{old}", json={"photos": first},
                                      headers=self.h(self.seller)).status_code, 200)
        self.assertEqual(work.step(), old)  # back to photos it had: worked at once, no wait left from before

    def test_an_edited_listing_goes_before_older_work(self):
        from vitrina_api.models import Listing, Media
        work = self.worker()
        ids = [self.post("/listings", self.seller, {**LISTING, "photos": self.four(c)}).json()["id"]
               for c in ((120, 90, 60), (60, 90, 120), (90, 120, 60))]
        while work.step() is not None:
            pass
        with self.app.state.sessions() as db:  # from before the change times were kept; the two newest need work
            for lid in ids:                   # again, as after a new model: older work
                db.get(Listing, lid).photos_changed_at = None
            for m in db.query(Media).filter(Media.listing_id.in_(ids[1:])):
                m.thumb_url = None
            db.commit()
        r = self.c.patch(f"/api/v1/listings/{ids[0]}", json={"photos": self.four((200, 200, 40))},
                         headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200)
        self.assertEqual([work.step() for _ in range(4)], [ids[0], ids[2], ids[1], None])  # then newest first

    def test_a_look_reads_only_listings_that_may_have_work(self):
        from sqlalchemy import event
        from vitrina_api import photo_work
        from vitrina_api.models import Listing, Media
        work = self.worker()
        label = self.upload(self.seller, solid((240, 240, 240))).json()["url"]
        done = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))
                                                   + [{"url": label, "angle": "label"}]}).json()["id"]
        odd = self.post("/listings", self.seller, {**LISTING, "photos": self.four((60, 90, 120))}).json()["id"]
        self.no_shoe_in((5, 5, 5))  # photos the model found no shoe in are done too: they stay as taken
        blank = self.post("/listings", self.seller, {**LISTING, "photos": self.four((5, 5, 5))}).json()["id"]
        while work.step() is not None:
            pass
        with self.app.state.sessions() as db:  # a photo no job can do anything with: a candidate for good
            db.add(Media(listing_id=odd, original_url="https://elsewhere.example/p.jpg", angle="detail", position=9))
            db.commit()
        loaded = []
        listen = lambda target, _ctx: loaded.append(target.id)  # noqa: E731
        event.listen(Listing, "load", listen)
        self.addCleanup(event.remove, Listing, "load", listen)
        self.assertIsNone(work.step())
        self.assertEqual(loaded, [odd])  # the finished listing with an uncut label is not even read
        loaded.clear()
        self.assertEqual(photo_work.due_work(self.app.state), {})  # nor by a look that remembers nothing
        self.assertEqual(loaded, [odd])
        loaded.clear()
        self.assertIsNone(work.step())
        self.assertEqual(loaded, [])  # nor the odd one again, until something about its photos changes
        with self.app.state.sessions() as db:
            db.query(Media).filter(Media.listing_id == odd, Media.angle == "front").update({"thumb_url": None})
            db.commit()
        self.assertEqual(work.step(), odd)
        self.assertNotIn(done, loaded)
        self.assertNotIn(blank, loaded)
        self.assertEqual(photo_work.due_work(self.app.state), {})  # the backfill's full look agrees

    def test_a_listing_the_worker_cannot_finish_waits_longer_each_time(self):
        from vitrina_api import photo_work
        work = self.worker()
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
        other = self.post("/listings", self.seller, {**LISTING, "photos": self.four((60, 90, 120))}).json()["id"]
        real = photo_work.thumb_listing
        tries = []

        def down(state, listing_id):
            if listing_id != lid:
                return real(state, listing_id)
            tries.append(listing_id)
            raise ConnectionError("storage is down")
        photo_work.thumb_listing = down
        self.addCleanup(setattr, photo_work, "thumb_listing", real)
        with self.assertLogs(level="ERROR"):
            self.assertEqual(work.step(), lid)
        self.assertEqual(work.step(), other)  # the first is waiting: it does not hold up the rest
        self.assertIsNone(work.step())  # still due, but waiting: the worker does not spin on it
        # A minute, doubling, up to an hour: each wait found by moving the clock to just before and just after it.
        for wait in (60, 120, 240, 480, 960, 1920, 3600, 3600):
            self.now[0] += wait - 1
            self.assertIsNone(work.step(), wait)
            self.now[0] += 1
            with self.assertLogs(level="ERROR"):
                self.assertEqual(work.step(), lid, wait)
        self.assertEqual(len(tries), 9)
        photo_work.thumb_listing = real  # the storage is back
        self.now[0] += photo_work.LONGEST_WAIT_S
        self.assertEqual(work.step(), lid)
        self.assertTrue(all(m["thumb_url"] for m in self.mine(lid)["media"]))
        self.assertIsNone(work.step())

    def test_the_photo_worker_stops_when_asked_and_survives_a_failed_look(self):
        import threading
        from vitrina_api import photo_work
        work = self.worker()
        real = photo_work.due_work
        looks, alive = [], []

        def flaky(state, **kw):
            looks.append(1)
            if len(looks) == 1:
                raise ConnectionError("database restarting")
            if len(looks) == 3:
                work.stop()
            return real(state, **kw)
        photo_work.due_work = flaky
        self.addCleanup(setattr, photo_work, "due_work", real)
        with self.assertLogs("vitrina_api.photo_work", level="ERROR"):
            work.run(0, alive=lambda: alive.append(1))
        self.assertEqual((len(looks), len(alive)), (3, 3))
        # Idle, it waits for the next look; asked to stop meanwhile, it does not finish the wait.
        idle = self.worker()
        runs = threading.Thread(target=idle.run, args=(60,), kwargs={"alive": lambda: alive.append(2)})
        runs.start()
        while 2 not in alive:
            runs.join(0.01)
        idle.stop()
        runs.join(5)
        self.assertFalse(runs.is_alive())

    def test_the_api_does_not_load_the_cut_out_model_when_a_worker_cuts_out(self):
        from vitrina_api import app as api
        from vitrina_api.config import Settings
        real = api.cutout.load_segmenter
        api.cutout.load_segmenter = lambda path: "model"
        self.addCleanup(setattr, api.cutout, "load_segmenter", real)
        for mode, segmenter in (("worker", None), ("inline", "model")):
            cfg = Settings(database_url=f"sqlite:///{os.path.join(self.tmp.name, mode + '.db')}",
                           media_dir=self.cfg.media_dir, photo_work=mode)
            made = api.create_app(cfg)
            self.assertEqual(made.state.segmenter, segmenter, mode)
            made.state.sessions.kw["bind"].dispose()

    def test_the_photo_worker_process_lowers_its_priority_and_stops_on_sigterm(self):
        import signal
        from vitrina_api import photo_worker
        from vitrina_api.config import Settings
        ran = []

        class Fake:
            def __init__(self, state):
                self.state = state

            def run(self, interval_s, alive):
                ran.append(interval_s)
                alive()
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

            def stop(self):
                ran.append("stopped")

        def no_nice(n):
            raise OSError("not permitted")
        alive = os.path.join(self.tmp.name, "alive")
        cfg = Settings(database_url=self.cfg.database_url, media_dir=self.cfg.media_dir, photo_worker_alive=alive,
                       photo_worker_interval_s=7)
        real = photo_worker.Worker, photo_worker.Settings, photo_worker.os.nice, signal.getsignal(signal.SIGTERM)
        root = logging.getLogger()
        self.addCleanup(setattr, root, "handlers", list(root.handlers))  # main() sets up logging for its process
        self.addCleanup(root.setLevel, root.level)
        photo_worker.Worker, photo_worker.Settings, photo_worker.os.nice = Fake, (lambda: cfg), no_nice
        try:
            with self.assertLogs("vitrina_api.photo_worker", level="WARNING") as said:
                photo_worker.main()
        finally:
            photo_worker.Worker, photo_worker.Settings, photo_worker.os.nice = real[:3]
            signal.signal(signal.SIGTERM, real[3])
        self.assertEqual(ran, [7, "stopped"])
        self.assertTrue(os.path.exists(alive))
        self.assertTrue(any("priority" in line for line in said.output))
        self.assertTrue(any("did not load" in line for line in said.output))  # no models in this test

    def with_segmenter(self):
        """The backfill gets the cut-out model the API has, as it would with VITRINA_CUTOUT_MODEL set."""
        from scripts import cutout_backfill
        real = cutout_backfill.cutout.load_segmenter
        cutout_backfill.cutout.load_segmenter = lambda path: self.app.state.segmenter
        self.addCleanup(setattr, cutout_backfill.cutout, "load_segmenter", real)

    def test_a_backfill_over_listings_that_are_done_reads_no_photos(self):
        from vitrina_api.models import Media
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        self.no_shoe_in(shades[2], (77, 77, 77))
        label = self.upload(self.seller, solid((9, 9, 9))).json()["url"]
        # A turn shown as taken, with a label left as taken; and photos all as taken: no backdrop, no cover frame.
        uncut = [self.post("/listings", self.seller, {**LISTING, "photos": self.four(shades[5]) + self.frames(shades)
                                                     + [{"url": label, "angle": "label"}]}).json()["id"],
                 self.post("/listings", self.seller, {**LISTING, "photos": self.four((77, 77, 77))
                                                      + self.frames(shades)}).json()["id"]]
        self.with_embedder()
        self.with_segmenter()
        code, out = self.backfill()  # the first run makes what is missing: here the search vectors
        self.assertEqual(code, 0, out)
        self.assertIn("2 of 2 listings done", out)
        storage, reads = self.app.state.storage, []
        real_read = storage.read
        storage.read = lambda url: reads.append(url) or real_read(url)
        self.addCleanup(setattr, storage, "read", real_read)
        code, out = self.backfill()
        self.assertEqual((code, out.strip(), reads), (0, "0 of 0 listings done", []))
        with self.app.state.sessions() as db:  # a photo missing its small copy is all a run then does
            db.query(Media).filter(Media.listing_id == uncut[1], Media.angle == "front").update({"thumb_url": None})
            db.commit()
        code, out = self.backfill()
        self.assertIn(f"listing {uncut[1]}: 1 small copies\n", out)

    def test_the_backfill_makes_small_copies_for_a_part_of_the_turn_it_leaves_as_taken(self):
        from sqlalchemy import select
        from vitrina_api.models import Media
        shades = [(20 + 25 * i,) * 3 for i in range(8)]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.frames(shades)}).json()["id"]
        with self.app.state.sessions() as db:  # one frame the model finds no shoe in, next to cut-out ones
            row = db.scalars(select(Media).where(Media.listing_id == lid).order_by(Media.position)).first()
            row.processed_url, row.no_cutout = None, "segmenter"
            db.commit()
        self.with_segmenter()
        code, out = self.backfill("--without-models")
        self.assertEqual(code, 0, out)
        self.assertIn(f"listing {lid}: 0 photos cut out, 7 small copies", out)
        self.assertTrue(all(m["processed_url"] is None and m["thumb_url"] for m in self.mine(lid)["media"]))

    def test_a_cut_out_made_later_drops_the_search_vector_of_the_photo_as_taken(self):
        from vitrina_api import visual
        from vitrina_api.models import ListingEmbedding
        self.app.state.segmenter = None
        lid = self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
        with self.app.state.sessions() as db:
            db.add(ListingEmbedding(listing_id=lid, model=visual.MODEL_NAME, vector=b"as taken"))
            db.commit()
        self.app.state.segmenter = center_segmenter
        self.with_segmenter()
        code, out = self.backfill("--without-models")  # no search model this time: the vector is made later
        self.assertIn(f"listing {lid}: 4 photos cut out, 4 small copies\n", out)
        with self.app.state.sessions() as db:
            self.assertIsNone(db.get(ListingEmbedding, lid))

    def test_the_backfill_stops_when_everything_fails_and_wants_its_models(self):
        from scripts import cutout_backfill
        from vitrina_api.models import Media
        ids = [self.post("/listings", self.seller, {**LISTING, "photos": self.four((120, 90, 60))}).json()["id"]
               for _ in range(cutout_backfill.STOP_AFTER + 2)]
        with self.app.state.sessions() as db:
            for m in db.query(Media).all():
                m.thumb_url = None
            db.commit()

        def down(state, lid):
            raise ConnectionError("storage is down")
        with self.assertLogs(level="ERROR"):
            code, out = self.backfill("--without-models", thumbs=down)
        self.assertEqual(code, 1)
        self.assertIn(f"0 of {len(ids)} listings done", out)
        self.assertEqual(out.count(": failed in "), cutout_backfill.STOP_AFTER)
        # Errors logged on one photo each are those listings' own: the run goes on past them.
        def gone(state, lid):
            logging.getLogger("vitrina_api.listing_routes").error("thumbnail failed for one photo")
        with self.assertLogs(level="ERROR"):
            code, out = self.backfill("--without-models", thumbs=gone)
        self.assertNotIn("stopped", out)
        self.assertEqual(out.count(": failed, see"), len(ids))
        # Without the models (none in the tests) nothing runs unless asked.
        code, out = self.backfill()
        self.assertEqual((code, out), (2, ""))

    def test_images_with_too_many_pixels_are_refused_before_decoding(self):
        out = io.BytesIO()
        Image.new("1", (8000, 7000)).save(out, "PNG")  # 56 MP, a few KB on the wire
        r = self.upload(self.seller, out.getvalue(), "p.png", "image/png")
        self.assertEqual((r.status_code, r.json()["code"]), (415, "unsupported_media"))


class ShowcaseUnitTests(unittest.TestCase):
    def test_a_black_shoe_on_a_white_sole_still_gets_a_light_backdrop(self):
        img = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rectangle((20, 40, 180, 130), fill=(20, 20, 24, 255))     # the black upper, the larger part
        d.rectangle((20, 131, 180, 180), fill=(250, 250, 250, 255))  # a thick white sole
        out = io.BytesIO()
        img.save(out, "PNG")
        self.assertEqual(backdrop_for(out.getvalue()), "light")

    def test_backdrop_ignores_the_transparent_surroundings(self):
        img = Image.new("RGBA", (300, 300), (255, 255, 255, 0))  # bright but see-through
        ImageDraw.Draw(img).rectangle((100, 100, 200, 200), fill=(10, 10, 10, 255))
        out = io.BytesIO()
        img.save(out, "WEBP", lossless=True)
        self.assertEqual(backdrop_for(out.getvalue()), "light")
        self.assertIsNone(backdrop_for(jpeg()))  # no cut-out, no backdrop

    def test_a_small_copy_keeps_its_colours(self):
        thumb = Image.open(io.BytesIO(make_thumb(solid((200, 30, 30), (1600, 1200)))))
        self.assertEqual(thumb.size, (480, 360))
        r, g, b = thumb.convert("RGB").getpixel((240, 180))
        self.assertTrue(abs(r - 200) < 8 and abs(g - 30) < 8 and abs(b - 30) < 8, (r, g, b))


DEMO = Path(__file__).resolve().parents[2] / "app" / "demo"


# CI checks out the whole repository, so there a missing demo is a failure, not a skip.
@unittest.skipUnless((DEMO / "api.json").exists() or os.environ.get("CI"), "the app is not next to the backend here")
class RealPhotoSideTests(unittest.TestCase):
    """The side matching on real photos: the demo's turntable shoe (2, and 4 in another colour) and camera scan (1,
    and 3 in another colour), whose sides were checked by eye on the phone (the toe faces the viewer at the front,
    the heel at the back). The demo's side photos are frames of the turn itself, so a seller's own shot is made from
    a frame a little off the side: smaller, moved, brighter and tilted."""

    CHECKED = {  # listing: side: frame of one turn
        1: {"outer": 36, "front": 14, "inner": 20, "back": 26},  # the camera goes round unevenly
        2: {"outer": 0, "front": 9, "inner": 18, "back": 27},
        3: {"outer": 36, "front": 14, "inner": 20, "back": 26},
        4: {"outer": 35, "front": 9, "inner": 18, "back": 27},
    }

    @staticmethod
    def shot(data: bytes) -> bytes:
        img = Image.open(io.BytesIO(data)).convert("RGBA")
        w, h = img.size
        img = img.rotate(3, resample=Image.BICUBIC).resize((int(w * 0.85), int(h * 0.85)), Image.LANCZOS)
        rgb = img.convert("RGB").point(lambda v: min(255, int(v * 1.15)))
        rgb.putalpha(img.getchannel("A"))
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        canvas.paste(rgb, ((w - rgb.width) // 2 + 6, (h - rgb.height) // 2))
        out = io.BytesIO()
        canvas.save(out, "WEBP")
        return out.getvalue()

    def test_a_shot_a_little_off_each_side_finds_the_frame_seen_on_the_phone(self):
        from types import SimpleNamespace
        from vitrina_api.cutout import side_frames
        from vitrina_api.serializers import one_turn
        answers = json.loads((DEMO / "api.json").read_text())

        def read(url):
            return (DEMO / "media" / url.split("/demo/media/")[1]).read_bytes()
        for lid, checked in self.CHECKED.items():
            listing = answers[f"GET /listings/{lid}"]
            media = [SimpleNamespace(**m) for m in listing["media"]]
            turn, _ = one_turn(media)
            n, urls = len(turn), [m.original_url for m in turn]
            # What the phone shows is what was checked.
            self.assertEqual({side: urls.index(url) for side, url in listing["angle_frames"].items()}, checked)
            frames = [read(m.thumb_url) for m in turn]
            stops = {side: urls.index(next(m for m in media if m.angle == side).original_url) for side in checked}
            for off in (-2, 2):
                with self.subTest(listing=lid, off=off):
                    found = side_frames({side: self.shot(frames[(k + off) % n]) for side, k in stops.items()}, frames)
                    # The toe and the heel exactly; a side within a couple of frames, where the shoe is about as wide.
                    self.assertEqual((found["front"], found["back"]), (checked["front"], checked["back"]))
                    for side in ("outer", "inner"):
                        gap = (found[side] - checked[side]) % n
                        self.assertLessEqual(min(gap, n - gap), 2, (side, found))
                    # Outer, front, inner, back: one way round, each a stretch of the turn after the one before.
                    at = [found[side] for side in ("outer", "front", "inner", "back")]
                    steps = [(b - a) % n for a, b in zip(at, at[1:] + at[:1])]
                    self.assertTrue(all(steps) and sum(steps) in (n, 3 * n), steps)


@unittest.skipUnless(os.environ.get("VITRINA_TEST_DATABASE_URL", "").startswith("postgresql"),
                     "set VITRINA_TEST_DATABASE_URL to a Postgres URL (CI does)")
class TurnMatchLockTests(unittest.TestCase):
    """The row lock only exists on Postgres, which production runs on."""

    def test_a_job_waits_for_a_seller_save_instead_of_deadlocking(self):
        import threading
        import time
        from sqlalchemy import update
        from vitrina_api.listing_routes import lock_fresh
        from vitrina_api.models import Listing, Media, User, make_session_factory
        sessions = make_session_factory(os.environ["VITRINA_TEST_DATABASE_URL"])
        with sessions() as db:
            user = User(phone=f"+7{time.time_ns() % 10**10:010d}")
            db.add(user)
            db.flush()
            listing = Listing(seller_id=user.id, title="t", category="sneakers", color="black", condition="new",
                              price_tiyn=1)
            listing.media.append(Media(original_url="a", angle="frame", position=0))
            db.add(listing)
            db.commit()
            lid, mid = listing.id, listing.media[0].id
        saving = threading.Event()
        failed = []

        def seller():  # a save writes the listing first, then its photos
            try:
                with sessions() as db:
                    db.execute(update(Listing).where(Listing.id == lid).values(title="new"))
                    saving.set()
                    time.sleep(1.5)  # longer than Postgres waits before it looks for a deadlock
                    db.execute(update(Media).where(Media.id == mid).values(position=1))
                    db.commit()
            except Exception as e:
                failed.append(e)
                saving.set()
        t = threading.Thread(target=seller)
        t.start()
        saving.wait(5)
        with sessions() as db:  # meanwhile the job made a small copy, and reads the listing again to write
            listing = db.get(Listing, lid)
            listing.media[0].thumb_url = "small"
            lock_fresh(db, listing)
            db.commit()
        t.join(10)
        self.assertEqual(failed, [])
        with sessions() as db:
            row = db.get(Listing, lid)
            self.assertEqual((row.title, row.media[0].thumb_url, row.media[0].position), ("new", "small", 1))


    def test_a_small_copy_for_a_photo_the_seller_is_deleting_waits_and_then_writes_nothing(self):
        import threading
        import time
        from vitrina_api.listing_routes import lock_fresh
        from vitrina_api.models import Listing, Media, User, make_session_factory
        from sqlalchemy import select, update
        sessions = make_session_factory(os.environ["VITRINA_TEST_DATABASE_URL"])
        with sessions() as db:
            user = User(phone=f"+7{time.time_ns() % 10**10:010d}")
            db.add(user)
            db.flush()
            listing = Listing(seller_id=user.id, title="t", category="sneakers", color="black", condition="new",
                              price_tiyn=1)
            listing.media += [Media(original_url="a", angle="frame", position=0),
                              Media(original_url="b", angle="frame", position=1)]
            db.add(listing)
            db.commit()
            lid, (keep, drop) = listing.id, [m.id for m in listing.media]
        saving = threading.Event()
        failed = []

        def seller():  # a save that drops a photo, the listing locked first, held open a while
            try:
                with sessions() as db:
                    row = db.get(Listing, lid, with_for_update=True)
                    row.media[:] = [m for m in row.media if m.id == keep]
                    db.flush()
                    saving.set()
                    time.sleep(1.5)
                    db.commit()
            except Exception as e:
                failed.append(e)
                saving.set()
        t = threading.Thread(target=seller)
        t.start()
        saving.wait(5)
        with sessions() as db:  # the job made small copies of both photos before the save
            listing = db.get(Listing, lid)
            lock_fresh(db, listing, [update(Media).where(Media.id == i, Media.thumb_url.is_(None))
                                     .values(thumb_url=f"small-{i}") for i in (keep, drop)])
            db.commit()
        t.join(10)
        self.assertEqual(failed, [])
        with sessions() as db:
            self.assertEqual(db.execute(select(Media.id, Media.thumb_url).where(Media.listing_id == lid)).all(),
                             [(keep, f"small-{keep}")])


@unittest.skipUnless(os.environ.get("VITRINA_CUTOUT_MODEL"), "set VITRINA_CUTOUT_MODEL to test the real model")
class RealModelTests(unittest.TestCase):
    def test_demo_frame_keeps_the_white_sole(self):
        from vitrina_api.cutout import load_segmenter
        here = os.path.dirname(__file__)
        data = open(os.path.join(here, "..", "demo", "frames", "street", "f00.jpg"), "rb").read()
        out = Image.open(io.BytesIO(process_photo(data, load_segmenter(os.environ["VITRINA_CUTOUT_MODEL"]))))
        # The white sole sits around (450, 560) in this frame; it must stay opaque.
        self.assertGreater(out.getchannel("A").getpixel((450, 560)), 200)
        self.assertLess(out.getchannel("A").getpixel((20, 20)), 10)


del MediaTests  # imported only as a base class; don't run its tests twice
