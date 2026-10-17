"""Background removal may only change transparency, never the product's colours or outline."""
import io
import os
import unittest

from PIL import Image, ImageDraw

from tests.test_api import LISTING, MediaTests, jpeg
from vitrina_api.cutout import cut_out, fill_holes, process_photo


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
