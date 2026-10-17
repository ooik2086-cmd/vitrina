"""Search by photo: ranking, filters, and behaviour without a model."""
import io
import os
import unittest

import numpy as np
from PIL import Image, ImageDraw

from tests.test_api import LISTING, ApiTestCase
from vitrina_api.visual import color_histogram, combine


def shoe_photo(colour, size=(800, 600)) -> bytes:
    img = Image.new("RGB", size, (245, 245, 245))
    ImageDraw.Draw(img).ellipse((150, 200, 650, 450), fill=colour)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=95)
    return out.getvalue()


def colour_only_embedder(data: bytes):
    """Stand-in for the model: the colour part alone, which is enough to check ranking end to end."""
    img = Image.open(io.BytesIO(data)).convert("RGB")
    return combine(np.ones(8, np.float32), color_histogram(img, None, np), np)


def colour_as_shape_embedder(data: bytes):
    """Stand-in whose "shape" part is the colour too, so tests can make look-alikes by colour."""
    img = Image.open(io.BytesIO(data)).convert("RGB")
    hist = color_histogram(img, None, np)
    return combine(hist + 1e-3, hist, np)


class ColourFeatureTests(unittest.TestCase):
    def hist(self, colour):
        return color_histogram(Image.open(io.BytesIO(shoe_photo(colour))).convert("RGB"), None, np)

    def test_backdrop_is_ignored_and_colours_differ(self):
        black, white_on_grey = self.hist((20, 20, 20)), self.hist((180, 180, 180))
        red, red2 = self.hist((200, 30, 30)), self.hist((190, 40, 35))
        self.assertGreater(float(red @ red2), 0.9)
        self.assertLess(float(red @ black), 0.1)
        self.assertLess(float(black @ white_on_grey), 0.1)

    def test_combined_vector_is_unit_length(self):
        v = combine(np.arange(1, 9, dtype=np.float32), self.hist((20, 20, 200)), np)
        self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0, places=5)


class ImageSearchApiTests(ApiTestCase):
    external_media = False

    def listing_with_photo(self, colour, **over):
        url = self.c.post("/api/v1/media", files={"file": ("p.jpg", shoe_photo(colour), "image/jpeg")},
                          headers=self.h(self.seller)).json()["url"]
        photos = [{"url": url, "angle": a} for a in ("front", "outer", "inner", "back", "sole")]
        lid = self.post("/listings", self.seller, {**LISTING, "photos": photos, **over}).json()["id"]
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).status_code, 200)
        return lid

    def search(self, colour, **params):
        return self.c.post("/api/v1/search/image", params=params,
                           files={"file": ("q.jpg", shoe_photo(colour), "image/jpeg")})

    def test_most_similar_first_and_filters_apply(self):
        self.app.state.embedder = colour_only_embedder
        red = self.listing_with_photo((200, 30, 30))
        blue = self.listing_with_photo((30, 40, 200), category="sport")
        black = self.listing_with_photo((20, 20, 20))
        items = self.search((210, 40, 30)).json()["items"]
        self.assertEqual(items[0]["id"], red)
        self.assertEqual({i["id"] for i in items}, {red, blue, black})
        self.assertGreater(items[0]["similarity"], items[-1]["similarity"])
        self.assertEqual([i["id"] for i in self.search((210, 40, 30), category="sport").json()["items"]], [blue])
        self.post(f"/listings/{red}/pause", self.seller)
        self.assertNotIn(red, [i["id"] for i in self.search((210, 40, 30)).json()["items"]])

    def test_similar_listings_exclude_itself_and_rank_by_look(self):
        self.app.state.embedder = colour_only_embedder
        red = self.listing_with_photo((200, 30, 30))
        red2 = self.listing_with_photo((190, 40, 35))
        black = self.listing_with_photo((20, 20, 20))
        ids = [i["id"] for i in self.c.get(f"/api/v1/listings/{red}/similar").json()["items"]]
        self.assertEqual(ids, [red2, black])
        self.app.state.embedder = None
        lonely = self.listing_with_photo((30, 40, 200))  # created without a model: no vector yet
        self.assertEqual(self.c.get(f"/api/v1/listings/{lonely}/similar").json()["items"], [])

    def test_photo_search_is_rate_limited_per_client(self):
        from vitrina_api.app import IMAGE_SEARCH_PER_MINUTE
        self.app.state.embedder = colour_only_embedder
        codes = [self.search((200, 30, 30)).status_code for _ in range(IMAGE_SEARCH_PER_MINUTE + 1)]
        self.assertEqual(codes[:-1], [200] * IMAGE_SEARCH_PER_MINUTE)
        self.assertEqual(codes[-1], 429)

    def test_seller_is_offered_brand_model_and_category_from_look_alikes(self):
        self.app.state.embedder = colour_as_shape_embedder
        self.listing_with_photo((200, 30, 30), brand="Nike", model_name="Air Force 1", category="sneakers")
        self.listing_with_photo((195, 35, 30), brand="Nike", model_name="Air Force 1", category="sneakers")
        self.listing_with_photo((20, 30, 200), brand="Adidas", model_name="Samba", category="classic")
        upload = lambda colour: self.c.post(  # noqa: E731
            "/api/v1/media", files={"file": ("p.jpg", shoe_photo(colour), "image/jpeg")},
            headers=self.h(self.seller)).json()["url"]
        r = self.post("/listings/suggest", self.seller, {"photo_url": upload((205, 32, 28))})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual((r.json()["brand"], r.json()["model_name"], r.json()["category"]),
                         ("Nike", "Air Force 1", "sneakers"))
        nothing_alike = self.post("/listings/suggest", self.seller, {"photo_url": upload((30, 200, 40))}).json()
        self.assertEqual((nothing_alike["brand"], nothing_alike["based_on"]), (None, 0))
        self.assertEqual(self.post("/listings/suggest", self.buyer, {"photo_url": upload((1, 1, 1))}).status_code, 403)
        self.assertEqual(self.post("/listings/suggest", self.seller, {"photo_url": "http://evil/x.jpg"}).json()["code"],
                         "foreign_media")

    def test_without_model_search_by_photo_is_unavailable(self):
        self.app.state.embedder = None
        r = self.search((200, 30, 30))
        self.assertEqual((r.status_code, r.json()["code"]), (503, "image_search_off"))


@unittest.skipUnless(os.environ.get("VITRINA_SEARCH_MODEL"), "set VITRINA_SEARCH_MODEL to test the real model")
class RealModelTests(unittest.TestCase):
    def test_same_colourway_ranks_first_from_another_angle(self):
        from vitrina_api.visual import load_embedder
        embed = load_embedder(os.environ["VITRINA_SEARCH_MODEL"])
        frames = os.path.join(os.path.dirname(__file__), "..", "demo", "frames")
        read = lambda v, f: open(os.path.join(frames, v, f), "rb").read()  # noqa: E731
        catalogue = {v: embed(read(v, "f00.jpg")) for v in ("street", "beach", "midnight")}
        for variant in catalogue:
            query = embed(read(variant, "f20.jpg"))
            best = max(catalogue, key=lambda v: float(catalogue[v] @ query))
            self.assertEqual(best, variant)
