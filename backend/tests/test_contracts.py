"""Rules the server shares with the app, checked against the same cases the app's tests read."""
import json
import re
import unittest
from pathlib import Path
from types import SimpleNamespace

from vitrina_api.serializers import one_turn, showcase_parts
from vitrina_api.social import find_contact, looks_like_contact

ROOT = Path(__file__).resolve().parents[2]


def name(url: str) -> str:
    return url.rsplit("/", 1)[-1].removesuffix(".jpg")


class ShowcasePartsTest(unittest.TestCase):
    """The cut-outs are kept or dropped per part, so the server must split the frames as the app shows them."""

    def check(self, label, media, parts, turn):
        with self.subTest(label):
            self.assertEqual([[name(m.original_url) for m in p] for p in showcase_parts(media)], parts)
            self.assertEqual(len(one_turn(media)[0]), turn)

    def test_cases_shared_with_the_app(self):
        cases = json.loads((ROOT / "contracts/showcase_parts.json").read_text())["cases"]
        self.assertGreater(len(cases), 5)
        for c in cases:
            media = [SimpleNamespace(angle=a, original_url=f"https://cdn/{n}.jpg") for a, n in c["media"]]
            self.check(c["name"], media, c["parts"], c["turn"])

    def test_demo_listings_split_as_recorded_for_the_app(self):
        """The app's test reads the same demo listings and the split written for them: each part's size and first
        frame (the app turns a plain turn to start at the cover's frame, so only a scan's order can be compared)."""
        demo = json.loads((ROOT / "app/demo/api.json").read_text())
        want = json.loads((ROOT / "contracts/showcase_parts_demo.json").read_text())["listings"]
        listings = {k: v for k, v in demo.items() if re.fullmatch(r"GET /listings/\d+", k)}
        self.assertEqual(sorted(want), sorted(listings))
        for key, listing in listings.items():
            media = [SimpleNamespace(angle=m["angle"], original_url=m["original_url"]) for m in listing["media"]]
            parts = showcase_parts(media)
            with self.subTest(key):
                self.assertEqual({"sizes": [len(p) for p in parts], "starts": [p[0].original_url for p in parts],
                                  "turn": len(one_turn(media)[0])}, want[key])


class ContactRuleTest(unittest.TestCase):
    """Public text refuses contacts; the app leaves the same ones out of the ready answers it offers there."""

    def test_cases_shared_with_the_app(self):
        cases = json.loads((ROOT / "contracts/contact_cases.json").read_text())
        self.assertGreater(len(cases["contact"]), 10)
        self.assertGreater(len(cases["not_contact"]), 10)
        for text in cases["contact"]:
            with self.subTest(text):
                self.assertTrue(looks_like_contact(text))
        for text in cases["not_contact"]:
            with self.subTest(text):
                self.assertFalse(looks_like_contact(text))



class FoundContactTest(unittest.TestCase):
    """What a refusal quotes for the seller to take out: each contact whole, as written, in the order written."""

    def test_what_the_seller_is_told_to_take_out(self):
        cases = {
            "Сұрақтар болса WhatsApp: +7 701 555 12 34": "WhatsApp: +7 701 555 12 34",  # the word and its number
            "тг: qadam": "тг: qadam",
            "Instagram, qadam@mail.ru, 8 701 123 45 67, t.me/q": "Instagram», «qadam@mail.ru», «8 701 123 45 67",
            "тел (8 701 123 45 67)": "8 701 123 45 67",
            "(70) 11-23-45-67": "(70) 11-23-45-67",
            "„qadam@mail.ru“.": "qadam@mail.ru",
            "Иә, 40 41 42 бар": None,
        }
        for text, want in cases.items():
            with self.subTest(text):
                self.assertEqual(find_contact(text), want)
        long = find_contact("https://" + "a" * 80 + ".kz")
        self.assertEqual((len(long), long[-1]), (60, "…"))  # cut with a mark, never silently

if __name__ == "__main__":
    unittest.main()
