"""Background removal may only change transparency, never the product's colours or outline."""
import io
import os
import unittest

from PIL import Image, ImageDraw

from tests.test_api import LISTING, MediaTests, jpeg
from vitrina_api.cutout import backdrop_for, cut_out, fill_holes, make_thumb, process_photo


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

    def test_a_close_up_photo_is_cut_out_like_the_top_and_sole(self):
        url = self.upload(self.seller, jpeg()).json()["url"]
        photos = self.four((120, 90, 60)) + [{"url": url, "angle": "detail"}]
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos})
        self.assertEqual(r.status_code, 201, r.text)
        detail = next(m for m in self.mine(r.json()["id"])["media"] if m["angle"] == "detail")
        self.assertTrue(detail["processed_url"].endswith(".webp"))

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
            cutout_backfill.main()
        finally:
            cutout_backfill.Settings, cutout_backfill.make_storage = real
        self.assertEqual(used, [self.cfg])
        self.assertTrue(all(m["thumb_url"] for m in self.mine(r.json()["id"])["media"]))

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
