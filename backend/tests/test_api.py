"""End-to-end API tests for scenarios A–E from the Phase 1 doc, plus security cases."""
import io
import json
import os
import re
import tempfile
import time
import unittest
from unittest import mock
from datetime import date, datetime, timedelta, timezone

from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import create_engine, func, select

os.environ.setdefault("VITRINA_LOG_LEVEL", "WARNING")  # keep test output to what failed

from vitrina_api import promo
from vitrina_api.app import create_app
from vitrina_api.config import Settings
from vitrina_api.models import Base, Conversation, Listing, ListingSize, Message, Offer, SavedSearch, User
from vitrina_api import jobs
from vitrina_api.services import (balance, run_auto_complete, run_expire_orders, run_review_reminders,
                                   run_stale_listing_tips)
from vitrina_core.money import PLATFORM_FEE, buyer_refund, escrow, seller_payable
from vitrina_core.webhooks import sign

PHOTOS = [{"url": f"https://cdn.example/p{i}.jpg", "angle": a}
          for i, a in enumerate(["front", "outer", "inner", "back", "sole"])]
LISTING = {
    "title": "Күнделікті кроссовка", "category": "sneakers", "brand": "Найк", "model_name": "Runner 01",
    "color": "құм", "condition": "used_excellent", "price_tiyn": 4_500_000, "delivery_price_tiyn": 150_000,
    "sizes": [{"label": "EU 42", "insole_cm": "26,5", "quantity": 1}], "photos": PHOTOS,
}

ADDRESS = {"recipient_name": "Айгерім Сапарова", "recipient_phone": "8 (701) 000-00-02", "city": "Алматы",
           "address": "Абай даңғылы 10, 25-пәтер"}


class ApiTestCase(unittest.TestCase):
    external_media = True

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        url = os.environ.get("VITRINA_TEST_DATABASE_URL")  # e.g. PostgreSQL in CI; each test starts empty
        if url:
            engine = create_engine(url)
            Base.metadata.drop_all(engine)
            engine.dispose()
        self.cfg = Settings(database_url=url or f"sqlite:///{os.path.join(self.tmp.name, 't.db')}", debug_otp=True, otp_resend_after=timedelta(0),
                            media_dir=os.path.join(self.tmp.name, "media"), public_media_url="http://test/media",
                            private_media_dir=os.path.join(self.tmp.name, "private"),
                            allow_external_media=self.external_media)
        self.app = create_app(self.cfg)
        self.c = TestClient(self.app)
        self.seller = self.login("+77010000001")
        self.post("/me/seller", self.seller, {"shop_name": "Qadam Store", "city": "Алматы"})
        self.buyer = self.login("+77010000002")

    def tearDown(self):
        self.c.close()
        self.app.state.sessions.kw["bind"].dispose()
        self.tmp.cleanup()

    # helpers
    def login(self, phone):
        code = self.c.post("/api/v1/auth/otp", json={"phone": phone}).json()["dev_code"]
        return self.c.post("/api/v1/auth/verify", json={"phone": phone, "code": code}).json()["token"]

    def h(self, token, **extra):
        return {"Authorization": f"Bearer {token}", **extra}

    def post(self, path, token, body=None, **headers):
        if path == "/orders" and body is not None and "delivery" not in body:
            body = {**body, "delivery": ADDRESS}  # every order needs an address; DeliveryTests cover it
        return self.c.post(f"/api/v1{path}", json=body or {}, headers=self.h(token, **headers))

    def publish(self, **over):
        r = self.post("/listings", self.seller, {**LISTING, **over})
        self.assertEqual(r.status_code, 201, r.text)
        lid = r.json()["id"]
        r = self.post(f"/listings/{lid}/publish", self.seller)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def hook(self, path, secret, event, ts=None, sig=None):
        body = json.dumps(event).encode()
        ts = ts or int(time.time())
        return self.c.post(f"/api/v1/webhooks/{path}", content=body, headers={
            "X-Timestamp": str(ts), "X-Signature": sig or sign(secret, ts, body), "Content-Type": "application/json"})

    def pay(self, order, event_id="evt_pay_1", amount=None):
        return self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": event_id, "type": "payment.succeeded", "order_id": order["id"],
            "amount_tiyn": order["total_tiyn"] if amount is None else amount, "currency": "KZT"})

    def deliver(self, tracking, event_id="dlv_1"):
        return self.hook("delivery/sandbox", self.cfg.delivery_webhook_secret,
                         {"id": event_id, "type": "delivery.delivered", "tracking_number": tracking})

    def ordered(self, key="k1"):
        listing = self.publish()
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]},
                      **{"Idempotency-Key": key})
        self.assertEqual(r.status_code, 201, r.text)
        return listing, r.json()

    def delivered(self):
        listing, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.assertEqual(self.pay(order).json()["status"], "PAID")
        self.assertEqual(self.post(f"/orders/{order['id']}/accept", self.seller).status_code, 200)
        self.assertEqual(self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": "KZ1"}).status_code, 200)
        self.assertEqual(self.deliver("KZ1").json()["status"], "DELIVERED_PENDING_CONFIRMATION")
        return listing, order

    def db(self):
        return self.app.state.sessions()

    def fetch(self, url):
        """A file through the address a response gave, as the app would load it."""
        r = self.c.get(url.removeprefix("http://test"))
        self.assertEqual(r.status_code, 200, url)
        return r

    def make_staff(self, phone="+77010000009"):
        token = self.login(phone)
        with self.db() as db:
            u = db.query(User).filter_by(phone=phone).one()
            u.role = "support"
            db.commit()
        return token


class FakeMobizon:
    """Mobizon's sendsmsmessage as its documentation describes it; answers with the code it is told to."""

    def __init__(self, code=0):
        self.code, self.sent = code, []

    def __call__(self, request):
        import httpx
        from urllib.parse import parse_qs
        if request.url.path != "/service/message/sendsmsmessage" or request.method != "POST":
            return httpx.Response(404)
        q = dict(request.url.params)
        if (q.get("output"), q.get("api"), q.get("apiKey")) != ("json", "v1", "secret-key"):
            return httpx.Response(200, json={"code": 8, "data": "", "message": "wrong key"})
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if self.code == 0:
            self.sent.append(form)
        return httpx.Response(200, json={"code": self.code, "data": {"messageId": 1}, "message": "no money"})


class SmsTests(ApiTestCase):
    """Sign-in codes go out by SMS through Mobizon; the code never comes back in the answer."""

    def setUp(self):
        super().setUp()
        import httpx
        from vitrina_api.sms import MobizonSender
        self.mobizon = FakeMobizon()
        self.app.state.sms = MobizonSender("secret-key", url="https://api.mobizon.kz", sender="VITRINA",
                                           client=httpx.Client(transport=httpx.MockTransport(self.mobizon)))
        self.app.state.settings.debug_otp = False

    def test_the_code_goes_by_sms_and_signs_in(self):
        r = self.c.post("/api/v1/auth/otp", json={"phone": "+77011234567"})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertNotIn("dev_code", r.json())
        [sms] = self.mobizon.sent
        self.assertEqual((sms["recipient"], sms["from"]), ("77011234567", "VITRINA"))
        code = sms["text"][:6]
        self.assertRegex(code, r"^\d{6}$")
        self.assertLessEqual(len(sms["text"]), 70)  # one Cyrillic SMS segment
        r = self.c.post("/api/v1/auth/verify", json={"phone": "+77011234567", "code": code})
        self.assertEqual(r.status_code, 200, r.text)

    def test_a_refused_sms_says_so_and_does_not_hold_the_next_try(self):
        from vitrina_api.models import OtpCode
        self.app.state.settings.otp_resend_after = timedelta(seconds=60)
        self.mobizon.code = 4  # e.g. no money left on the account
        with self.assertLogs("vitrina_api.auth_routes", "ERROR") as logs:
            r = self.c.post("/api/v1/auth/otp", json={"phone": "+77011234567"})
        self.assertEqual((r.status_code, r.json()["code"]), (503, "sms_failed"))
        self.assertIn("code 4", logs.output[0])
        self.assertNotIn("secret-key", " ".join(logs.output))
        self.assertNotIn("1234567", " ".join(logs.output))  # not the whole number either
        with self.db() as db:
            self.assertEqual(db.scalar(select(func.count(OtpCode.id)).where(OtpCode.phone == "+77011234567")), 0)  # taken back
        self.mobizon.code = 0
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": "+77011234567"}).status_code, 200)

    def test_an_unreachable_provider_does_not_leak_the_key(self):
        import httpx
        from vitrina_api.sms import MobizonSender, SmsError

        def down(request):
            raise httpx.ConnectError(f"cannot reach {request.url}")
        sender = MobizonSender("secret-key", client=httpx.Client(transport=httpx.MockTransport(down)))
        with self.assertRaises(SmsError) as err:
            sender.send("+77011234567", "x")
        self.assertNotIn("secret-key", str(err.exception))
        self.assertIsNone(err.exception.__cause__)
        bad = MobizonSender("wrong", client=httpx.Client(transport=httpx.MockTransport(FakeMobizon())))
        with self.assertRaises(SmsError):
            bad.send("+77011234567", "x")

    def test_the_daily_cap_stops_sending(self):
        from vitrina_api.models import OtpCode
        with self.db() as db:  # the test's own sign-ins count too
            self.app.state.settings.sms_per_day = db.scalar(select(func.count(OtpCode.id))) + 2
        for phone in ("+77011234561", "+77011234562"):
            self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": phone}).status_code, 200)
        with self.assertLogs("vitrina_api.auth_routes", "ERROR"):
            r = self.c.post("/api/v1/auth/otp", json={"phone": "+77011234563"})
        self.assertEqual((r.status_code, r.json()["code"]), (503, "sms_failed"))
        self.assertEqual(len(self.mobizon.sent), 2)

    def test_the_provider_is_chosen_by_settings(self):
        from vitrina_api.sms import MobizonSender, make_sender
        self.assertIsNone(make_sender(Settings()))
        self.assertIsInstance(make_sender(Settings(sms_provider="mobizon", mobizon_api_key="k")), MobizonSender)
        with self.assertRaises(RuntimeError):
            make_sender(Settings(sms_provider="smsc"))


class AuthTests(ApiTestCase):
    def test_bad_phone_rejected(self):
        r = self.c.post("/api/v1/auth/otp", json={"phone": "87010000000"})
        self.assertEqual(r.json()["code"], "invalid_phone")
        self.assertIn("message_kk", r.json())

    def test_otp_attempts_lock_out(self):
        self.c.post("/api/v1/auth/otp", json={"phone": "+77010000003"})
        for _ in range(self.cfg.otp_max_attempts):
            self.assertEqual(self.c.post("/api/v1/auth/verify", json={"phone": "+77010000003", "code": "000000"}).status_code, 400)
        r = self.c.post("/api/v1/auth/verify", json={"phone": "+77010000003", "code": "000000"})
        self.assertEqual(r.json()["code"], "otp_expired")

    def test_otp_rate_limit(self):
        for _ in range(self.cfg.otp_per_phone_per_hour):
            self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": "+77010000004"}).status_code, 200)
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": "+77010000004"}).status_code, 429)

    def test_a_second_code_waits_a_minute_and_says_how_long(self):
        self.app.state.settings.otp_resend_after = timedelta(seconds=60)
        first = self.c.post("/api/v1/auth/otp", json={"phone": "+77010000006"}).json()
        self.assertEqual(first["resend_after"], 60)
        again = self.c.post("/api/v1/auth/otp", json={"phone": "+77010000006"})
        self.assertEqual((again.status_code, again.json()["code"]), (429, "otp_too_soon"))
        self.assertTrue(0 < int(again.json()["detail"]) <= 60)
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": "+77010000007"}).status_code, 200)

    def test_the_first_code_still_works_after_send_again_and_a_used_code_does_not_hold_the_next(self):
        phone = "+77010000008"
        first = self.c.post("/api/v1/auth/otp", json={"phone": phone}).json()["dev_code"]
        self.c.post("/api/v1/auth/otp", json={"phone": phone})
        r = self.c.post("/api/v1/auth/verify", json={"phone": phone, "code": first})
        self.assertEqual(r.status_code, 200, r.text)
        self.app.state.settings.otp_resend_after = timedelta(seconds=60)
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": phone}).status_code, 200)  # signed in: no wait

    def test_the_hourly_cap_says_how_long_to_wait(self):
        for _ in range(self.cfg.otp_per_phone_per_hour):
            self.c.post("/api/v1/auth/otp", json={"phone": "+77010000009"})
        r = self.c.post("/api/v1/auth/otp", json={"phone": "+77010000009"}).json()
        self.assertEqual(r["code"], "rate_limited")
        self.assertTrue(3000 < int(r["detail"]) <= 3600, r)

    def test_a_burst_of_parallel_requests_sends_one_code(self):
        import threading
        self.app.state.settings.otp_resend_after = timedelta(seconds=60)
        barrier, codes = threading.Barrier(12), []

        def ask():
            barrier.wait()
            codes.append(self.c.post("/api/v1/auth/otp", json={"phone": "+77010000010"}).status_code)
        threads = [threading.Thread(target=ask) for _ in range(12)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(codes.count(200), 1, codes)

    def test_refused_requests_do_not_use_up_the_address(self):
        self.app.state.settings.otp_resend_after = timedelta(seconds=60)
        self.c.post("/api/v1/auth/otp", json={"phone": "+77010000011"})
        for _ in range(30):
            self.c.post("/api/v1/auth/otp", json={"phone": "+77010000011"})
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": "+77010000012"}).status_code, 200)

    def test_requests_without_token_rejected(self):
        self.assertEqual(self.c.get("/api/v1/me").status_code, 401)
        self.assertEqual(self.c.get("/api/v1/me", headers={"Authorization": "Bearer nope"}).status_code, 401)


class ListingTests(ApiTestCase):
    def test_buyer_must_enable_seller_mode(self):
        self.assertEqual(self.post("/listings", self.buyer, LISTING).json()["code"], "seller_required")

    def test_publish_needs_photos_and_defects(self):
        lid = self.post("/listings", self.seller, {**LISTING, "photos": PHOTOS[:2]}).json()["id"]
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["code"], "missing_required_photos")
        lid = self.post("/listings", self.seller, {**LISTING, "condition": "defective", "defects": "Жыртық"}).json()["id"]
        r = self.post(f"/listings/{lid}/publish", self.seller)
        self.assertEqual(r.json()["code"], "defects_required")  # no close-up photo of the defect

    def test_card_keeps_segment_condition_authenticity_apart_and_hides_phone(self):
        card = self.publish()
        self.assertEqual(card["condition"], "used_excellent")
        self.assertEqual(card["authenticity"], "unverified")
        self.assertIsNone(card["segment"])  # fewer than 200 listings: no segment is invented
        self.assertNotIn("phone", json.dumps(card["seller"]))

    def test_search_cyrillic_brand_and_size(self):
        self.publish()
        self.assertEqual(len(self.c.get("/api/v1/listings", params={"q": "кроссовка nike"}).json()["items"]), 1)
        self.assertEqual(len(self.c.get("/api/v1/listings", params={"q": "найк", "size_cm": "26,7"}).json()["items"]), 1)
        self.assertEqual(len(self.c.get("/api/v1/listings", params={"size_cm": "28"}).json()["items"]), 0)

    def test_drafts_are_private(self):
        lid = self.post("/listings", self.seller, LISTING).json()["id"]
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").status_code, 404)
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}", headers=self.h(self.seller)).status_code, 200)


class WeightTests(ApiTestCase):
    """What a page of the catalog costs the phone and the server."""

    def test_a_catalog_page_comes_compressed(self):
        for i in range(3):
            self.publish(title=f"Аяқкиім {i}")
        r = self.c.get("/api/v1/listings", headers={"Accept-Encoding": "gzip"})
        self.assertEqual(r.headers.get("content-encoding"), "gzip")
        self.assertEqual(len(r.json()["items"]), 3)  # the client unpacks it
        r = self.c.get("/api/v1/listings", headers={"Accept-Encoding": "identity"})
        self.assertIsNone(r.headers.get("content-encoding"))  # a client that cannot unpack gets it as is

    def test_photos_videos_and_pdfs_are_sent_as_they_are(self):
        from starlette.responses import Response
        from vitrina_api.app import CompressText

        async def file(scope, receive, send):
            await Response(b"x" * 5000, media_type="application/octet-stream")(scope, receive, send)
        c = TestClient(CompressText(file))
        for path in ("/media/1/a.jpg", "/api/v1/private-media/1/b.mp4", "/api/v1/orders/1/slip.pdf"):
            self.assertIsNone(c.get(path, headers={"Accept-Encoding": "gzip"}).headers.get("content-encoding"), path)
        self.assertEqual(c.get("/api/v1/me/sales.csv", headers={"Accept-Encoding": "gzip"})
                         .headers.get("content-encoding"), "gzip")

    def test_a_page_of_one_shop_reads_its_seller_once(self):
        from sqlalchemy import event
        for i in range(5):
            self.publish(title=f"Аяқкиім {i}")
        engine = self.app.state.sessions.kw["bind"]
        asked = []
        listen = lambda *a: asked.append(a[2])  # noqa: E731
        event.listen(engine, "before_cursor_execute", listen)
        try:
            self.c.get("/api/v1/listings")
        finally:
            event.remove(engine, "before_cursor_execute", listen)
        self.assertEqual(sum(re.search(r"\bFROM users\b", q) is not None for q in asked), 1, asked)

    def test_price_bands_are_read_again_only_when_prices_change(self):
        from sqlalchemy import event, insert, update
        from vitrina_api.models import Listing
        first = self.publish()
        with self.db() as db:
            src = db.get(Listing, first["id"])
            row = {c.key: getattr(src, c.key) for c in Listing.__mapper__.column_attrs if c.key != "id"}
            db.execute(insert(Listing), [{**row, "price_tiyn": (i + 1) * 1000} for i in range(250)])
            db.commit()
        engine = self.app.state.sessions.kw["bind"]
        asked = []
        listen = lambda *a: asked.append(a[2])  # noqa: E731

        def segment_and_reads():
            asked.clear()
            event.listen(engine, "before_cursor_execute", listen)
            try:
                card = self.c.get(f"/api/v1/listings/{first['id']}").json()
            finally:
                event.remove(engine, "before_cursor_execute", listen)
            return card["segment"], sum("SELECT listings.price_tiyn" in q for q in asked)
        price = first["price_tiyn"]  # dearer than any copy: the top band
        self.assertEqual(segment_and_reads(), ("luxury", 1))
        self.assertEqual(segment_and_reads(), ("luxury", 0))  # nothing changed: the bands are kept
        with self.db() as db:
            db.execute(update(Listing).where(Listing.id != first["id"]).values(price_tiyn=Listing.price_tiyn + price))
            db.commit()
        self.assertEqual(segment_and_reads(), ("economy", 1))  # now the cheapest: read again

    def test_a_page_reads_its_photos_once_and_shows_them_as_the_listing_page_does(self):
        from sqlalchemy import event
        made = [self.publish(title=f"Аяқкиім {i}") for i in range(3)]
        turned = [{"url": m["original_url"], "angle": m["angle"]} for m in reversed(made[0]["media"])]
        r = self.c.patch(f"/api/v1/listings/{made[0]['id']}", json={"photos": turned}, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)  # the same rows in a new order
        for listing in made:
            self.post(f"/favorites/{listing['id']}", self.buyer)
        from vitrina_api.models import Media
        engine = self.app.state.sessions.kw["bind"]
        asked, built = [], []
        listen = lambda *a: asked.append(a[2])  # noqa: E731
        build = lambda target, _ctx: built.append(target)  # noqa: E731
        pages = {}
        for name, path, who in (("feed", "/api/v1/listings", None), ("favorites", "/api/v1/favorites", self.buyer),
                                ("mine", "/api/v1/me/listings", self.seller)):
            asked.clear()
            event.listen(engine, "before_cursor_execute", listen)
            event.listen(Media, "load", build)
            try:
                r = self.c.get(path, headers=self.h(who) if who else {})
            finally:
                event.remove(engine, "before_cursor_execute", listen)
                event.remove(Media, "load", build)
            self.assertEqual(r.status_code, 200, r.text)
            pages[name] = r.json()["items"]
            self.assertEqual(sum(re.search(r"\bFROM media\b", q) is not None for q in asked), 1, (name, asked))
            self.assertEqual(built, [], name)  # photos are read as plain rows: ~43 objects a card cost a third of a page
        for name, items in pages.items():
            self.assertEqual(len(items), 3, name)
            for item in items:
                page = self.c.get(f"/api/v1/listings/{item['id']}",
                                  headers=self.h(self.seller) if name == "mine" else {}).json()
                self.assertTrue(item["media"], name)
                for key in ("media", "cover_frame", "angle_frames", "photos_version"):
                    self.assertEqual(item[key], page[key], (name, key))
        first = next(i for i in pages["feed"] if i["id"] == made[0]["id"])
        self.assertEqual([m["original_url"] for m in first["media"]], [p["url"] for p in turned])


class EarningsTests(ApiTestCase):
    def test_seller_sees_held_then_payable_minus_commission(self):
        self.assertEqual(self.c.get("/api/v1/me/earnings", headers=self.h(self.buyer)).status_code, 403)
        _, order = self.delivered()
        e = self.c.get("/api/v1/me/earnings", headers=self.h(self.seller)).json()
        self.assertEqual(e["held_tiyn"], order["total_tiyn"])
        self.assertEqual((e["payable_tiyn"], e["items"]), (0, []))
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        e = self.c.get("/api/v1/me/earnings", headers=self.h(self.seller)).json()
        self.assertEqual(e["held_tiyn"], 0)
        self.assertGreater(e["fees_tiyn"], 0)
        self.assertEqual(e["payable_tiyn"] + e["fees_tiyn"], order["total_tiyn"])
        self.assertEqual(e["items"][0]["net_tiyn"], e["payable_tiyn"])
        self.assertEqual(e["items"][0]["kind"], "completion")
        self.assertEqual(e["items"][0]["listing_title"], LISTING["title"])


def with_check_digit(first11: str) -> str:
    """A valid IIN/BIN from its first 11 digits, for tests."""
    d = [int(c) for c in first11]
    check = sum(d[i] * (i + 1) for i in range(11)) % 11
    if check == 10:
        check = sum(d[i] * w for i, w in enumerate((3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2))) % 11
    return first11 + str(check)


IBAN = "KZ86125KZT5004100100"  # the IBAN registry's own example for Kazakhstan


class PayoutTests(ApiTestCase):
    def completed(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        return self.c.get("/api/v1/me/earnings", headers=self.h(self.seller)).json()["payable_tiyn"]

    def account(self, **over):
        body = {"holder_name": "ЖК Qadam  Store", "iban": "kz86 125K ZT50 0410 0100",
                "tax_id": with_check_digit("90010130012"), **over}
        return self.c.put("/api/v1/me/payout-account", json=body, headers=self.h(self.seller))

    def test_bank_details_are_checked_before_they_are_kept(self):
        self.assertEqual(self.account(iban="KZ87125KZT5004100100").json()["code"], "invalid_iban")
        self.assertEqual(self.account(iban="RU0204452560040702810412345678901").json()["code"], "invalid_iban")
        tax = with_check_digit("90010130012")
        wrong = tax[:11] + str((int(tax[11]) + 1) % 10)
        self.assertEqual(self.account(tax_id=wrong).json()["code"], "invalid_tax_id")
        r = self.account()
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["account"], {"holder_name": "ЖК Qadam Store", "iban": IBAN,
                                               "iban_masked": "KZ86 •••• 0100", "tax_id": tax})
        self.assertEqual(self.c.get("/api/v1/me/payout-account", headers=self.h(self.buyer)).status_code, 403)

    def test_payout_moves_money_out_once_and_support_pays_or_returns_it(self):
        self.assertEqual(self.post("/me/payouts", self.seller).json()["code"], "payout_account_required")
        self.account()
        self.assertEqual(self.post("/me/payouts", self.seller).json()["code"], "payout_too_small")
        owed = self.completed()
        self.assertEqual(self.post("/me/payouts", self.seller, {"amount_tiyn": owed + 1}).json()["code"],
                         "payout_exceeds")
        r = self.post("/me/payouts", self.seller, {"amount_tiyn": owed - 100_000})
        self.assertEqual(r.status_code, 201, r.text)
        first = r.json()
        self.assertEqual((first["status"], first["iban_masked"]), ("requested", "KZ86 •••• 0100"))
        self.assertEqual(self.post("/me/payouts", self.seller).json()["code"], "payout_open")
        mine = self.c.get("/api/v1/me/payouts", headers=self.h(self.seller)).json()
        self.assertEqual((mine["payable_tiyn"], mine["open"], mine["has_account"]), (100_000, True, True))
        # A changed account later does not redirect a request already made.
        self.account(iban="KZ86125KZT5004100100", holder_name="Басқа адам")
        staff = self.make_staff()
        self.assertEqual(self.c.get("/api/v1/admin/payouts", headers=self.h(self.seller)).status_code, 403)
        queue = self.c.get("/api/v1/admin/payouts", headers=self.h(staff)).json()["items"]
        self.assertEqual(self.c.get("/api/v1/admin/overview", headers=self.h(staff)).json()["queues"]["payouts"], 1)
        self.assertEqual([(q["id"], q["holder_name"], q["shop_name"]) for q in queue],
                         [(first["id"], "ЖК Qadam Store", "Qadam Store")])
        r = self.post(f"/admin/payouts/{first['id']}/paid", staff, {"bank_ref": "ПП-1042"})
        self.assertEqual(r.json()["status"], "paid")
        self.assertEqual(self.post(f"/admin/payouts/{first['id']}/reject", staff, {"reason": "x"}).json()["code"],
                         "payout_decided")
        with self.db() as db:
            self.assertEqual(balance(db, f"payout:{first['id']}"), 0)
            self.assertEqual(balance(db, seller_payable("1")), 100_000)
        # The rest, asked for and sent back, returns to the balance.
        second = self.post("/me/payouts", self.seller).json()
        self.assertEqual(second["amount_tiyn"], 100_000)
        r = self.post(f"/admin/payouts/{second['id']}/reject", staff, {"reason": "Шот иесінің аты сәйкес емес"})
        self.assertEqual(r.json()["status"], "rejected")
        mine = self.c.get("/api/v1/me/payouts", headers=self.h(self.seller)).json()
        self.assertEqual((mine["payable_tiyn"], mine["open"]), (100_000, False))
        self.assertEqual([i["status"] for i in mine["items"]], ["rejected", "paid"])
        notes = self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
        self.assertTrue(any("ПП" not in n["text"] and "KZ86 •••• 0100" in n["text"] for n in notes))
        # Money still owed keeps the account from being deleted.
        self.assertEqual(self.c.delete("/api/v1/me", headers=self.h(self.seller)).json()["code"], "payout_owed")


class StaleListingTests(ApiTestCase):
    def test_a_listing_unsold_for_three_weeks_gets_one_tip_that_fits_it(self):
        from vitrina_api.models import Listing
        seen, unseen, sold = self.publish()["id"], self.publish()["id"], self.publish()["id"]
        self.post("/orders", self.buyer, {"listing_id": sold, "size_id": self.c.get(f"/api/v1/listings/{sold}").json()
                                          ["sizes"][0]["id"]}, **{"Idempotency-Key": "st"})
        now = datetime.now(timezone.utc)
        with self.db() as db:
            for lid in (seen, unseen, sold):
                db.get(Listing, lid).announced_at = now - timedelta(days=22)
            db.get(Listing, seen).views = 40
            db.commit()
            self.assertEqual(run_stale_listing_tips(db, now=now - timedelta(days=2)), [])  # not three weeks yet
            self.assertEqual(sorted(run_stale_listing_tips(db, now=now)), sorted([seen, unseen]))
            self.assertEqual(run_stale_listing_tips(db, now=now + timedelta(days=30)), [])  # once only
        notes = [n["text"] for n in self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
                 if n["kind"] == "listing_tip"]
        self.assertEqual(len(notes), 2)
        self.assertTrue(any("40 рет қаралды" in t and "5–10%" in t for t in notes))
        self.assertTrue(any("360°" in t for t in notes))  # the test listings have photos but no 360° frames


class SlipTests(ApiTestCase):
    def test_seller_prints_a_slip_only_once_the_order_is_paid(self):
        _, order = self.ordered()
        url = f"/api/v1/orders/{order['id']}/slip.pdf"
        self.assertEqual(self.c.get(url, headers=self.h(self.seller)).json()["code"], "invalid_status")
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        self.assertEqual(self.c.get(url, headers=self.h(self.buyer)).status_code, 404)  # the seller's tool only
        r = self.c.get(url, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.headers["content-type"], "application/pdf")
        self.assertTrue(r.content.startswith(b"%PDF"))


class DeliveryEstimateTests(ApiTestCase):
    def test_estimate_adds_the_sellers_shipping_time_to_transit(self):
        from vitrina_api.delivery_eta import known_city, transit_days
        self.assertEqual((known_city(" алма-ата "), known_city("Nur-Sultan"), known_city("Москва")),
                         ("Алматы", "Астана", None))
        self.assertEqual(transit_days("Алматы", "Алматы"), (1, 2))
        self.assertEqual(transit_days("Алматы", "Астана"), (3, 5))  # ~970 km
        listing = self.publish()
        url = f"/api/v1/listings/{listing['id']}/delivery-estimate"
        self.assertIsNone(self.c.get(url).json()["estimate"])  # nobody to deliver to yet
        e = self.c.get(url, params={"city": "Астана"}).json()["estimate"]
        self.assertEqual((e["from_city"], e["city"], e["handling_days"]), ("Алматы", "Астана", 2))
        today = date.fromisoformat(e["earliest"]) - timedelta(days=5)
        self.assertEqual(date.fromisoformat(e["latest"]) - today, timedelta(days=7))
        # The city of the buyer's last order is used without asking; a seller who ships same day gets 0 days.
        _, order = self.ordered("k2")
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        self.post(f"/orders/{order['id']}/accept", self.seller)
        self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": "KZ9"})
        e = self.c.get(url, headers=self.h(self.buyer)).json()["estimate"]
        self.assertEqual((e["city"], e["handling_days"]), ("Алматы", 0))
        self.assertEqual(date.fromisoformat(e["latest"]) - date.fromisoformat(e["earliest"]), timedelta(days=1))
        # While the shop is away, the count starts the day after it is back.
        back = date.fromisoformat(e["earliest"]) + timedelta(days=9)
        self.assertEqual(self.c.put("/api/v1/me/away", json={"until": back.isoformat()},
                                    headers=self.h(self.seller)).status_code, 200)
        e = self.c.get(url, headers=self.h(self.buyer)).json()["estimate"]
        self.assertEqual(date.fromisoformat(e["earliest"]), back + timedelta(days=2))

    def test_shop_page_says_how_soon_it_ships_once_there_are_three_orders(self):
        shop = f"/api/v1/sellers/{self.publish()['seller']['id']}"
        for i in range(3):
            self.assertIsNone(self.c.get(shop).json()["ship_time"])
            _, order = self.ordered(f"s{i}")
            self.post(f"/orders/{order['id']}/pay", self.buyer)
            self.pay(order, event_id=f"evt_s{i}")
            self.post(f"/orders/{order['id']}/accept", self.seller)
            self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": f"KZS{i}"})
        t = self.c.get(shop).json()["ship_time"]
        self.assertEqual((t["orders"], t["bucket"], t["hours"]), (3, "day", 0))


class PopularityTests(ApiTestCase):
    def test_only_real_demand_is_shown(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 3}])
        url = f"/api/v1/listings/{listing['id']}"
        self.assertIsNone(self.c.get(url).json()["popularity"])
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]},
                      **{"Idempotency-Key": "p1"})
        self.assertIsNone(self.c.get(url).json()["popularity"])  # an unpaid order is not a sale
        self.post(f"/orders/{r.json()['id']}/pay", self.buyer)
        self.pay(r.json())
        self.assertEqual(self.c.get(url).json()["popularity"], {"sold_30d": 1, "favorites": 0})
        for i in range(3):
            token = self.buyer if i == 0 else self.login(f"+7701000010{i}")
            self.post(f"/favorites/{listing['id']}", token)
        self.assertEqual(self.c.get(url).json()["popularity"], {"sold_30d": 1, "favorites": 3})


class ColorwayTests(ApiTestCase):
    def colors(self, listing_id):
        return self.c.get(f"/api/v1/listings/{listing_id}").json()["colors"]

    def test_same_model_in_other_colours_from_the_same_shop(self):
        sand = self.publish()
        self.assertEqual(self.colors(sand["id"]), [])  # one colour: nothing to choose
        black = self.publish(color="Қара", model_name="runner  01", brand="найк", price_tiyn=4_000_000)
        dear_black = self.publish(color="қара", price_tiyn=4_900_000)
        sold_out = self.publish(color="көк", price_tiyn=3_000_000)
        with self.db() as db:
            db.query(ListingSize).filter_by(listing_id=sold_out["id"]).update({"quantity": 0})
            db.commit()
        self.publish(color="ақ", model_name="Runner 02")  # another model
        self.publish(color="ақ", brand="Адидас")  # another brand
        other_shop = self.login("+77010000003")
        self.post("/me/seller", other_shop, {"shop_name": "Басқа", "city": "Алматы"})
        r = self.post("/listings", other_shop, {**LISTING, "color": "қызыл"})
        self.post(f"/listings/{r.json()['id']}/publish", other_shop)
        paused = self.publish(color="жасыл")
        self.post(f"/listings/{paused['id']}/pause", self.seller)

        got = self.colors(sand["id"])
        # By colour name (көк, қара, құм), this one among them: the swatches keep their places.
        self.assertEqual([(c["id"], c["current"]) for c in got],
                         [(sold_out["id"], False), (black["id"], False), (sand["id"], True)])
        self.assertFalse(got[0]["in_stock"])
        self.assertEqual(got[1]["price_tiyn"], 4_000_000)
        self.assertTrue(got[2]["thumb_url"])
        # From the black one, its own colour is itself, not the dearer black pair; the order stays.
        self.assertEqual([(c["id"], c["current"]) for c in self.colors(black["id"])],
                         [(sold_out["id"], False), (black["id"], True), (sand["id"], False)])
        self.assertNotIn(dear_black["id"], [c["id"] for c in got])

    def test_a_colour_typed_in_russian_or_english_is_one_colour_with_its_kazakh_name(self):
        here = self.publish(color="көк")
        black = self.publish(color="Черный")
        self.assertEqual(black["color"], "қара")
        self.publish(color="black", price_tiyn=9_000_000)  # the same colour: no second swatch
        self.assertEqual([c["color"] for c in self.colors(here["id"])], ["көк", "қара"])
        r = self.c.patch(f"/api/v1/listings/{here['id']}", json={"color": "Red"}, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["color"], "қызыл")
        found = self.c.get("/api/v1/listings", params={"q": "красные"}).json()["items"]
        self.assertIn(here["id"], [l["id"] for l in found])  # searched again by its new colour
        # A buyer searching in Russian or English still finds it.
        for q in ("черный", "черные найк", "black", "қара", "кара"):
            found = self.c.get("/api/v1/listings", params={"q": q}).json()["items"]
            self.assertIn(black["id"], [l["id"] for l in found], q)

    def test_a_colour_stored_before_the_list_still_groups_with_its_kazakh_name(self):
        here = self.publish(color="көк")
        old = self.publish(color="қара")
        with self.db() as db:
            db.query(Listing).filter_by(id=old["id"]).update({"color": "Черный"})  # as typed before the picker
            db.commit()
        self.assertIn(old["id"], [c["id"] for c in self.colors(here["id"])])
        self.publish(color="black")
        self.assertEqual(len(self.colors(here["id"])), 2)  # still one black swatch

    def test_a_blank_or_invisible_colour_is_refused(self):
        for color in ("   ", " а ", "\u200b\u200b"):
            r = self.post("/listings", self.seller, {**LISTING, "color": color})
            self.assertEqual(r.status_code, 422, color)

    def test_no_model_name_no_colours(self):
        a = self.publish(model_name=None)
        self.publish(model_name=None, color="қара")
        self.assertEqual(self.colors(a["id"]), [])
        b = self.publish(model_name="  ")
        self.publish(model_name="  ", color="көк")
        self.assertEqual(self.colors(b["id"]), [])  # a blank name is no model either

    def test_a_colour_opens_the_pair_closest_in_condition_then_in_stock_then_cheapest(self):
        new = self.publish(condition="new_with_box", price_tiyn=6_000_000)
        worn = self.publish(condition="used_excellent", price_tiyn=2_000_000)
        cheap_worn_black = self.publish(color="қара", condition="used_excellent", price_tiyn=1_000_000)
        new_black = self.publish(color="қара", condition="new_no_box", price_tiyn=5_000_000)
        cheap_new_black = self.publish(color="қара", condition="unworn_stored", price_tiyn=4_000_000)
        with self.db() as db:
            db.query(ListingSize).filter_by(listing_id=cheap_new_black["id"]).update({"quantity": 0})
            db.commit()
        self.publish(color="көк", category="kids")  # a kids' pair of the same name is another shoe

        def black(listing):
            return [c["id"] for c in self.colors(listing["id"]) if not c["current"]]

        self.assertEqual(black(new), [new_black["id"]])  # new beside new, and in stock before cheaper
        self.assertEqual(black(worn), [cheap_worn_black["id"]])  # worn beside worn

    def test_past_the_cap_colours_in_stock_stay(self):
        here = self.publish(color="ақ")
        names = [f"түс {i:02d}" for i in range(13)]
        made = {name: self.publish(color=name)["id"] for name in names}
        with self.db() as db:
            db.query(ListingSize).filter(ListingSize.listing_id.in_([made[n] for n in names[:2]])).update(
                {"quantity": 0})
            db.commit()
        got = self.colors(here["id"])
        self.assertEqual(len(got), 12)
        shown = {c["id"] for c in got}
        self.assertTrue(all(made[n] not in shown for n in names[:2]))  # the sold-out ones give way
        self.assertTrue(all(c["in_stock"] for c in got))

    def test_the_page_opens_without_colours_when_they_fail(self):
        listing = self.publish()
        self.publish(color="қара")
        with mock.patch("vitrina_api.listing_routes.colorways", side_effect=RuntimeError("boom")), \
                self.assertLogs("vitrina", level="ERROR"):
            r = self.c.get(f"/api/v1/listings/{listing['id']}")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["colors"], [])

    def test_the_catalog_shows_only_the_colours_asked_for_in_any_of_their_words(self):
        black, blue = self.publish(color="қара"), self.publish(color="көк")
        self.publish(color="қызыл")
        marble = self.publish(color="мраморный")
        two_tone = self.publish(color="черно-белый")
        find = lambda color: sorted(i["id"] for i in self.c.get(  # noqa: E731
            "/api/v1/listings", params={"color": color}).json()["items"])
        self.assertEqual(find("қара,Blue"), sorted([black["id"], blue["id"], two_tone["id"]]))
        self.assertEqual(find("черные"), sorted([black["id"], two_tone["id"]]))  # black-and-white is black too
        self.assertEqual(find("қара-ақ"), [two_tone["id"]])
        self.assertEqual(find(" , мраморный"), [marble["id"]])  # a typed colour, as typed
        self.assertEqual(len(find("")), 5)  # no colour: every colour
        self.assertEqual(len(find(" , \u200b")), 5)  # only blank parts: every colour, as a saved search reads it


class DidYouMeanTests(ApiTestCase):
    def test_an_empty_search_offers_the_nearest_spelling_on_sale(self):
        self.publish(brand="Nike", model_name="Air Force", title="Nike Air Force кроссовка")
        find = lambda q: self.c.get("/api/v1/listings", params={"q": q}).json()  # noqa: E731
        self.assertEqual(find("nkie")["did_you_mean"], "Nike")
        self.assertEqual(find("nike froce")["did_you_mean"], "Nike force")
        self.assertNotIn("did_you_mean", find("nike"))  # found something: no hint
        self.assertIsNone(find("zzzzzz")["did_you_mean"])


class CityFilterTests(ApiTestCase):
    def test_catalog_filters_by_the_sellers_city_however_it_is_spelled(self):
        mine = self.publish()["id"]  # Qadam Store, Алматы
        other = self.login("+77010000005")
        self.post("/me/seller", other, {"shop_name": "Astana Kicks", "city": "Nur-Sultan"})
        r = self.c.post("/api/v1/listings", json=LISTING, headers=self.h(other))
        theirs = r.json()["id"]
        self.post(f"/listings/{theirs}/publish", other)
        ids = lambda city: [i["id"] for i in self.c.get("/api/v1/listings", params={"city": city}).json()["items"]]  # noqa: E731
        self.assertEqual(ids("almaty"), [mine])
        self.assertEqual(ids("Астана"), [theirs])
        self.assertEqual(ids("Москва"), [])
        self.assertEqual(sorted(i["id"] for i in self.c.get("/api/v1/listings").json()["items"]), [mine, theirs])


class ReportTests(ApiTestCase):
    def report(self, lid, token, reason="fake", text=None):
        return self.post(f"/listings/{lid}/report", token, {"reason": reason, "text": text})

    def test_reports_queue_for_moderator_who_hides_and_everyone_is_told(self):
        lid = self.publish()["id"]
        other = self.login("+77010000003")
        self.assertEqual(self.report(lid, self.seller).json()["code"], "own_listing")
        self.assertEqual(self.report(lid, self.buyer, "other").json()["code"], "reason_required")
        self.assertEqual(self.report(lid, self.buyer).status_code, 201)
        self.assertEqual(self.report(lid, self.buyer, "wrong_photos").json()["code"], "already_reported")
        self.assertEqual(self.report(lid, other, "contact_details", "Телефонын суретке жазған").status_code, 201)
        # reports alone never hide a listing
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").status_code, 200)
        staff = self.make_staff()
        self.assertEqual(self.c.get("/api/v1/admin/reports", headers=self.h(self.buyer)).status_code, 403)
        queue = self.c.get("/api/v1/admin/reports", headers=self.h(staff)).json()["items"]
        self.assertEqual([(i["listing"]["id"], len(i["reports"])) for i in queue], [(lid, 2)])
        r = self.post(f"/admin/reports/{lid}/close", staff, {"action": "hide", "reason": "Брендтің көшірмесі"})
        self.assertEqual(r.json(), {"listing_id": lid, "status": "hidden", "closed": 2})
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").status_code, 404)
        self.assertEqual(self.c.get("/api/v1/admin/reports", headers=self.h(staff)).json()["items"], [])
        for token, kind in ((self.seller, "listing_hidden"), (self.buyer, "report_closed"), (other, "report_closed")):
            items = self.c.get("/api/v1/notifications", headers=self.h(token)).json()["items"]
            self.assertIn(kind, [n["kind"] for n in items])

    def test_dismiss_keeps_listing_live(self):
        lid = self.publish()["id"]
        self.report(lid, self.buyer)
        staff = self.make_staff()
        r = self.post(f"/admin/reports/{lid}/close", staff, {"action": "dismiss", "reason": "Фото шынайы"})
        self.assertEqual(r.json()["status"], "published")
        self.assertEqual(self.post(f"/admin/reports/{lid}/close", staff,
                                   {"action": "dismiss", "reason": "again"}).status_code, 404)


class ShopTests(ApiTestCase):
    def test_shop_profile_counts_and_seller_filter(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        live = self.publish()["id"]
        p = self.c.get(f"/api/v1/sellers/{order['seller_id']}").json()
        self.assertEqual((p["shop_name"], p["city"], p["completed_sales"], p["listings"]),
                         ("Qadam Store", "Алматы", 1, 1))
        self.assertNotIn("phone", p)
        ids = [i["id"] for i in self.c.get("/api/v1/listings", params={"seller_id": order["seller_id"]}).json()["items"]]
        self.assertEqual(ids, [live])
        self.assertEqual(self.c.get(f"/api/v1/sellers/{order['buyer_id']}").status_code, 404)


class CatalogFilterTests(ApiTestCase):
    def test_sort_and_condition_list(self):
        a = self.publish(price_tiyn=3_000_000, condition="new_with_box")["id"]
        b = self.publish(price_tiyn=1_000_000, condition="used_excellent")["id"]
        c = self.publish(price_tiyn=2_000_000, condition="used_good", defects="Сызат")["id"]
        ids = lambda **q: [i["id"] for i in self.c.get("/api/v1/listings", params=q).json()["items"]]
        self.assertEqual(ids(), [c, b, a])
        self.assertEqual(ids(sort="price_asc"), [b, c, a])
        self.assertEqual(ids(sort="price_desc"), [a, c, b])
        self.assertEqual(ids(condition="new_with_box,used_excellent", sort="price_asc"), [b, a])
        self.assertEqual(ids(min_price_tiyn=1_500_000, max_price_tiyn=2_500_000), [c])
        self.assertEqual(ids(limit=1, offset=1), [b])
        self.assertEqual(self.c.get("/api/v1/listings", params={"sort": "cheap"}).status_code, 422)


class SellerEditTests(ApiTestCase):
    def patch(self, lid, body, token=None):
        return self.c.patch(f"/api/v1/listings/{lid}", json=body, headers=self.h(token or self.seller))

    def test_seller_changes_price_and_stock_and_pauses(self):
        listing = self.publish(condition="used_good", defects="Табанында кішкене сызат")
        lid, size_id = listing["id"], listing["sizes"][0]["id"]
        self.assertEqual(self.patch(lid, {"price_tiyn": 4_000_000}, self.buyer).status_code, 404)
        r = self.patch(lid, {"price_tiyn": 4_000_000, "sizes": [{"id": size_id, "quantity": 3}]})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["price_tiyn"], 4_000_000)
        self.assertEqual(r.json()["sizes"][0]["quantity"], 3)
        self.assertNotIn("quantity", self.c.get(f"/api/v1/listings/{lid}").json()["sizes"][0])
        self.assertEqual(self.patch(lid, {"defects": " "}).json()["code"], "defects_required")
        self.assertEqual(self.post(f"/listings/{lid}/pause", self.seller).json()["status"], "paused")
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").status_code, 404)
        r = self.post("/orders", self.buyer, {"listing_id": lid, "size_id": size_id}, **{"Idempotency-Key": "p"})
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["status"], "published")

    def test_owner_sees_views_favorites_chats_and_orders(self):
        listing = self.publish()
        lid = listing["id"]
        self.c.get(f"/api/v1/listings/{lid}")
        self.c.get(f"/api/v1/listings/{lid}", headers=self.h(self.buyer))
        self.c.get(f"/api/v1/listings/{lid}", headers=self.h(self.seller))  # the seller's own visits don't count
        self.post(f"/favorites/{lid}", self.buyer)
        self.post("/conversations", self.buyer, {"listing_id": lid})
        self.post("/orders", self.buyer, {"listing_id": lid, "size_id": listing["sizes"][0]["id"]},
                  **{"Idempotency-Key": "s1"})
        public = self.c.get(f"/api/v1/listings/{lid}").json()
        self.assertNotIn("stats", public)
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]
        self.assertEqual(mine["stats"], {"views": 3, "favorites": 1, "chats": 1, "orders": 1, "sold": 0})

    def test_price_drop_tells_people_who_saved_the_listing(self):
        listing = self.publish()
        lid = listing["id"]
        self.post(f"/favorites/{lid}", self.buyer)
        self.patch(lid, {"price_tiyn": 4_490_000})  # under 1% off: not news
        self.patch(lid, {"price_tiyn": 4_800_000})  # a rise: not news either
        self.patch(lid, {"price_tiyn": 3_900_000})
        notes = [n for n in self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]
                 if n["kind"] == "price_drop"]
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["listing_id"], lid)
        self.assertIn("48 000 ₸ → 39 000 ₸", notes[0]["text"])
        self.assertIn("подешевел", notes[0]["text_ru"])

    def test_seller_analytics_by_day_with_top_listings(self):
        a, b = self.publish(), self.publish(title="Екінші кроссовка")
        for _ in range(3):
            self.c.get(f"/api/v1/listings/{a['id']}", headers=self.h(self.buyer))
        self.c.get(f"/api/v1/listings/{b['id']}")
        self.c.get(f"/api/v1/listings/{a['id']}", headers=self.h(self.seller))  # own visits don't count
        self.post("/orders", self.buyer, {"listing_id": a["id"], "size_id": a["sizes"][0]["id"]},
                  **{"Idempotency-Key": "an1"})
        r = self.c.get("/api/v1/me/analytics", headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        self.assertEqual(len(data["days"]), 14)
        self.assertEqual(data["days"][-1]["views"], 4)
        self.assertEqual((data["totals"]["views"], data["totals"]["orders"]), (4, 1))
        self.assertEqual(data["totals"]["conversion"], 0.25)
        self.assertEqual([t["id"] for t in data["top"]], [a["id"], b["id"]])
        self.assertEqual(self.c.get("/api/v1/me/analytics", headers=self.h(self.buyer)).status_code, 403)

    def test_stock_drives_sold_and_restock(self):
        listing = self.publish()
        lid, size_id = listing["id"], listing["sizes"][0]["id"]
        self.assertEqual(self.patch(lid, {"sizes": [{"id": size_id, "quantity": 0}]}).json()["status"], "sold")
        self.assertEqual(self.patch(lid, {"sizes": [{"id": size_id, "quantity": 2}]}).json()["status"], "paused")
        self.assertEqual(self.patch(lid, {"sizes": [{"id": 9999, "quantity": 2}]}).status_code, 422)

    def test_a_save_on_a_count_a_buyer_changed_meanwhile_is_refused(self):
        listing, order = self.ordered()  # the seller's screen still shows the one pair the buyer just took
        lid, size_id = listing["id"], listing["sizes"][0]["id"]
        r = self.patch(lid, {"sizes": [{"id": size_id, "quantity": 2, "was": 1}]})
        self.assertEqual((r.status_code, r.json()["code"]), (409, "stock_changed"), r.text)
        with self.db() as db:
            self.assertEqual(db.get(ListingSize, size_id).quantity, 0)
        r = self.patch(lid, {"price_tiyn": 4_000_000})  # a save that leaves stock alone is not stopped by it
        self.assertEqual(r.status_code, 200, r.text)
        r = self.patch(lid, {"sizes": [{"id": size_id, "quantity": 2, "was": 0}]})
        self.assertEqual(r.json()["sizes"][0]["quantity"], 2)

    def test_seller_cannot_lift_moderation_hide(self):
        lid = self.publish()["id"]
        staff = self.make_staff()
        self.post(f"/admin/listings/{lid}/hide", staff, {"reason": "fake brand"})
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).status_code, 409)
        self.assertEqual(self.patch(lid, {"price_tiyn": 1_000_000}).status_code, 409)


class OrderFlowTests(ApiTestCase):
    def test_scenario_a_happy_path_and_settlement(self):
        _, order = self.delivered()
        r = self.post(f"/orders/{order['id']}/confirm", self.buyer)
        self.assertEqual(r.json()["status"], "COMPLETED")
        with self.db() as db:
            fee = self.cfg.commission.fee_for(4_500_000)
            self.assertEqual(balance(db, PLATFORM_FEE), fee)
            seller_id = db.query(User).filter_by(phone="+77010000001").one().id
            self.assertEqual(balance(db, seller_payable(str(seller_id))), 4_650_000 - fee)
            self.assertEqual(balance(db, escrow(str(order["id"]))), 0)

    def test_order_creation_is_idempotent_and_reserves_stock(self):
        listing, order = self.ordered("same-key")
        again = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]},
                          **{"Idempotency-Key": "same-key"})
        self.assertEqual(again.json()["id"], order["id"])
        other = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]},
                          **{"Idempotency-Key": "new-key"})
        # Sold out: said so, not "not found", to a buyer who saw it on sale a moment ago.
        self.assertEqual((other.status_code, other.json()["code"]), (409, "out_of_stock"))

    def test_order_lists_are_per_party(self):
        _, order = self.ordered()
        mine = self.c.get("/api/v1/orders", headers=self.h(self.buyer)).json()["items"]
        self.assertEqual([o["id"] for o in mine], [order["id"]])
        self.assertEqual(mine[0]["listing_title"], LISTING["title"])
        self.assertEqual((mine[0]["size_label"], mine[0]["size_cm"]), (LISTING["sizes"][0]["label"], "26,5"))
        sold = self.c.get("/api/v1/orders?role=seller", headers=self.h(self.seller)).json()["items"]
        self.assertEqual([o["id"] for o in sold], [order["id"]])
        self.assertEqual(self.c.get("/api/v1/orders?role=seller", headers=self.h(self.buyer)).json()["items"], [])

    def test_cancel_before_payment_restocks(self):
        listing, order = self.ordered()
        self.assertEqual(self.post(f"/orders/{order['id']}/cancel", self.buyer).json()["status"], "CANCELLED")
        self.assertEqual(self.c.get(f"/api/v1/listings/{listing['id']}").json()["status"], "published")

    def test_other_users_cannot_see_or_touch_order(self):
        _, order = self.ordered()
        stranger = self.login("+77010000005")
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(stranger)).status_code, 404)
        self.assertEqual(self.post(f"/orders/{order['id']}/accept", stranger).status_code, 404)
        self.assertEqual(self.post(f"/orders/{order['id']}/accept", self.buyer).status_code, 404)

    def test_scenario_c_dispute_partial_refund(self):
        _, order = self.delivered()
        self.assertEqual(self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Жасырын ақау"}).json()["status"], "DISPUTED")
        staff = self.make_staff()
        self.assertEqual(self.post(f"/admin/orders/{order['id']}/resolve", self.buyer,
                                   {"refund_tiyn": 1, "reason": "x"}).status_code, 403)
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 1_000_000, "reason": "Фото ақауды растайды", "early": True})
        self.assertEqual(r.json()["status"], "REFUND_PENDING")
        bad = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "rf_0", "type": "refund.succeeded", "order_id": order["id"], "amount_tiyn": 5, "currency": "KZT"})
        self.assertEqual(bad.status_code, 409)
        ok = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "rf_1", "type": "refund.succeeded", "order_id": order["id"], "amount_tiyn": 1_000_000, "currency": "KZT"})
        self.assertEqual(ok.json()["status"], "REFUNDED")
        with self.db() as db:
            buyer_id = db.query(User).filter_by(phone="+77010000002").one().id
            # The provider sent the refund, so the platform no longer owes the buyer anything.
            self.assertEqual(balance(db, buyer_refund(str(buyer_id))), 0)
            self.assertEqual(balance(db, escrow(str(order["id"]))), 0)

    def test_scenario_d_auto_complete_after_window_only(self):
        _, order = self.delivered()
        with self.db() as db:
            now = datetime.now(timezone.utc)
            self.assertEqual(run_auto_complete(db, now=now + timedelta(days=1), window=self.cfg.confirm_window,
                                               rule=self.cfg.commission), [])
            self.assertEqual(run_auto_complete(db, now=now + timedelta(days=6), window=self.cfg.confirm_window,
                                               rule=self.cfg.commission), [order["id"]])
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["status"], "COMPLETED")

    def test_buyer_gets_one_review_reminder_a_few_days_after_completion(self):
        _, order = self.delivered()
        now = datetime.now(timezone.utc)
        with self.db() as db:
            run_auto_complete(db, now=now + timedelta(days=6), window=self.cfg.confirm_window, rule=self.cfg.commission)
            self.assertEqual(run_review_reminders(db, now=now + timedelta(days=7)), [])  # too soon
            self.assertEqual(run_review_reminders(db, now=now + timedelta(days=10)), [order["id"]])
            self.assertEqual(run_review_reminders(db, now=now + timedelta(days=11)), [])  # only once
        items = self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]
        reminder = next(n for n in items if n["kind"] == "review_reminder")
        self.assertEqual(reminder["order_id"], order["id"])
        self.assertIn("қалай болды?", reminder["text"])
        self.assertIn("How is", reminder["text_en"])

    def test_no_review_reminder_once_the_buyer_reviewed(self):
        _, order = self.delivered()
        self.assertEqual(self.post(f"/orders/{order['id']}/confirm", self.buyer).status_code, 200)
        self.assertEqual(self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 5}).status_code, 201)
        with self.db() as db:
            self.assertEqual(run_review_reminders(db, now=datetime.now(timezone.utc) + timedelta(days=4)), [])

    def test_jobs_pass_runs_both_jobs(self):
        self.delivered()
        self.assertEqual(jobs.run_once(self.app.state.sessions, self.cfg),
                         {"cancelled": [], "refunded": [], "disputed": [], "completed": [], "review_reminders": [],
                          "listing_tips": [], "purged": []})

    def test_unpaid_order_lets_go_of_the_pair_after_half_an_hour(self):
        listing, order = self.ordered()
        size = listing["sizes"][0]["id"]
        avail = lambda: next(s for s in self.c.get(f"/api/v1/listings/{listing['id']}").json()["sizes"]
                             if s["id"] == size)["available"]
        self.assertFalse(avail())  # the only pair is held by the order
        got = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()
        self.assertGreater(datetime.fromisoformat(got["deadline"]), datetime.now(timezone.utc) + timedelta(minutes=29))
        now = datetime.now(timezone.utc)
        with self.db() as db:
            self.assertEqual(run_expire_orders(db, now=now + timedelta(minutes=10))["cancelled"], [])
            self.assertEqual(run_expire_orders(db, now=now + timedelta(minutes=31))["cancelled"], [order["id"]])
        self.assertTrue(avail())
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["status"],
                         "CANCELLED")

    def test_paid_order_the_seller_ignores_is_refunded_after_two_days(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.assertEqual(self.pay(order).json()["status"], "PAID")
        now = datetime.now(timezone.utc)
        with self.db() as db:
            self.assertEqual(run_expire_orders(db, now=now + timedelta(hours=47))["refunded"], [])
            self.assertEqual(run_expire_orders(db, now=now + timedelta(hours=49))["refunded"], [order["id"]])
        got = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()
        self.assertEqual((got["status"], got["deadline"]), ("REFUND_PENDING", None))
        refund = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "evt_ref_1", "type": "refund.succeeded", "order_id": order["id"],
            "amount_tiyn": order["total_tiyn"], "currency": "KZT"})
        self.assertEqual(refund.json()["status"], "REFUNDED")

    def test_payment_after_cancel_is_held_and_refunded(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.assertEqual(self.post(f"/orders/{order['id']}/cancel", self.buyer).json()["status"], "CANCELLED")
        late = self.pay(order)
        self.assertEqual(late.json(), {"result": "refund", "status": "REFUND_PENDING"})
        refund = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "evt_ref_1", "type": "refund.succeeded", "order_id": order["id"],
            "amount_tiyn": order["total_tiyn"], "currency": "KZT"})
        self.assertEqual(refund.json()["status"], "REFUNDED")
        with self.db() as db:
            self.assertEqual(balance(db, escrow(str(order["id"]))), 0)


def jpeg(size=(800, 600), orientation=None, gps=False) -> bytes:
    img = Image.new("RGB", size, (200, 30, 30))
    exif = Image.Exif()
    if orientation:
        exif[0x0112] = orientation
    if gps:
        exif[0x8825] = {1: "N", 2: (43.0, 15.0, 0.0)}  # GPSInfo
    out = io.BytesIO()
    img.save(out, "JPEG", exif=exif.tobytes())
    return out.getvalue()


@unittest.skipUnless(promo.available(), "ffmpeg not installed")
class PromoTests(ApiTestCase):
    external_media = False

    def test_seller_makes_a_promo_video_and_a_price_change_retires_it(self):
        urls = [self.c.post("/api/v1/media", files={"file": ("p.jpg", jpeg(), "image/jpeg")},
                            headers=self.h(self.seller)).json()["url"] for _ in range(4)]
        photos = [{"url": u, "angle": a} for u, a in zip(urls, ("front", "outer", "inner", "back"))]
        listing = self.publish(photos=photos)
        lid = listing["id"]
        self.assertEqual(listing["promo"], {"state": None, "url": None})
        self.assertEqual(self.post(f"/listings/{lid}/promo", self.buyer).status_code, 404)
        r = self.post(f"/listings/{lid}/promo", self.seller, {"lang": "ru"})
        self.assertEqual(r.status_code, 202, r.text)
        self.assertEqual(r.json()["promo"]["state"], "rendering")
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]["promo"]
        self.assertEqual(mine["state"], "ready")  # the test client runs background jobs before returning
        video = os.path.join(self.cfg.media_dir, mine["url"].removeprefix("http://test/media/"))
        with open(video, "rb") as f:
            self.assertEqual(f.read(12)[4:8], b"ftyp")  # an MP4 container
        self.assertNotIn("promo", self.c.get(f"/api/v1/listings/{lid}").json())  # only the seller sees it
        r = self.c.patch(f"/api/v1/listings/{lid}", json={"price_tiyn": 3_900_000}, headers=self.h(self.seller))
        self.assertEqual(r.json()["promo"], {"state": None, "url": None})  # it showed the old price

    def test_a_video_that_cannot_be_made_is_said_so(self):
        urls = [self.c.post("/api/v1/media", files={"file": ("p.jpg", jpeg(), "image/jpeg")},
                            headers=self.h(self.seller)).json()["url"] for _ in range(4)]
        lid = self.publish(photos=[{"url": u, "angle": a} for u, a in zip(urls, ("front", "outer", "inner", "back"))])["id"]
        with mock.patch.object(promo, "render_video", side_effect=RuntimeError("ffmpeg died")), \
                self.assertLogs("vitrina.api", "ERROR"):
            self.post(f"/listings/{lid}/promo", self.seller, {"lang": "kk"})
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][0]["promo"]
        self.assertEqual(mine, {"state": "failed", "url": None})  # the seller may try again, not wait for ever


class OpsTests(ApiTestCase):
    def test_health_answers_with_the_database(self):
        self.assertEqual(self.c.get("/api/v1/health").json(), {"ok": True})

    def test_production_refuses_development_defaults(self):
        from vitrina_api.app import create_app
        from vitrina_api.config import production_problems
        dev = Settings(env="production", database_url="sqlite://", media_dir=self.tmp.name)
        with self.assertRaises(RuntimeError) as err:
            create_app(dev)
        for env in ("VITRINA_DEBUG_OTP", "VITRINA_OTP_SECRET", "VITRINA_PAYMENT_SECRET", "VITRINA_DELIVERY_SECRET",
                    "VITRINA_AUTO_CREATE_SCHEMA", "VITRINA_DATABASE_URL"):
            self.assertIn(env, str(err.exception))
        ready = Settings(env="production", debug_otp=False, auto_create_schema=False, otp_secret=b"o" * 40,
                         payment_webhook_secret=b"p" * 40, delivery_webhook_secret=b"d" * 40,
                         database_url="postgresql+psycopg://u:p@db/vitrina", media_dir=self.tmp.name,
                         public_media_url="https://cdn.vitrina.kz", cors_origins=[], s3_bucket="vitrina",
                         s3_endpoint="https://s3.example.kz", s3_access_key="k", s3_secret_key="s",
                         s3_private_bucket="vitrina-private", s3_backup_bucket="vitrina-backup",
                         photo_work="worker", sms_provider="mobizon", mobizon_api_key="k")
        self.assertEqual(production_problems(ready), [])
        from dataclasses import replace
        for loose, env in ((dict(cors_origins=["*"]), "VITRINA_CORS_ORIGINS"),
                           (dict(allow_external_media=True), "VITRINA_ALLOW_EXTERNAL_MEDIA"),
                           (dict(s3_bucket=""), "VITRINA_S3_BUCKET"), (dict(s3_access_key=""), "VITRINA_S3_ACCESS_KEY"),
                           (dict(photo_work="inline"), "VITRINA_PHOTO_WORK"),
                           (dict(s3_backup_bucket=""), "VITRINA_S3_BACKUP_BUCKET"),
                           (dict(s3_backup_bucket="vitrina-private"), "VITRINA_S3_BACKUP_BUCKET"),
                           (dict(sms_provider=""), "VITRINA_SMS_PROVIDER"), (dict(mobizon_api_key=""), "VITRINA_MOBIZON_API_KEY"),
                           (dict(mobizon_url="http://api.mobizon.kz"), "VITRINA_MOBIZON_URL")):
            self.assertIn(env, " ".join(production_problems(replace(ready, **loose))))


class ShareTests(ApiTestCase):
    def test_shared_link_shows_a_preview_page_for_published_listings_only(self):
        listing = self.publish(title="Ақ кеды <b>", sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 1}])
        r = self.c.get(f"/l/{listing['id']}")
        self.assertEqual(r.status_code, 200)
        page = r.text
        self.assertIn('<meta property="og:title" content="Ақ кеды &lt;b&gt; · 45 000 ₸">', page)
        self.assertIn('property="og:image"', page)
        self.assertIn("EU 42 · 26,5 см", page)
        self.assertIn(f'href="vitrina://open/listing/{listing["id"]}"', page)
        self.assertIn('href="/s/1">Сатушы: Qadam Store →', page)
        self.assertNotIn("<b>", page.split("<body>")[1])  # seller text is escaped
        self.assertNotIn("+7701", page)  # never the seller's phone
        self.assertIn("Открыть в приложении", self.c.get(f"/l/{listing['id']}", headers={"Accept-Language": "ru-RU"}).text)
        english = self.c.get(f"/l/{listing['id']}", headers={"Accept-Language": "en-US,en;q=0.9"}).text
        self.assertIn("Open in the app", english)
        self.assertIn("Worn, excellent", english)
        self.post(f"/listings/{listing['id']}/pause", self.seller)
        self.assertEqual(self.c.get(f"/l/{listing['id']}").status_code, 404)
        self.assertEqual(self.c.get("/l/99999").status_code, 404)

    def test_shared_shop_page_lists_what_is_on_sale_with_the_platforms_own_facts(self):
        on_sale = self.publish(title="Ақ кеды <b>")
        paused = self.publish(title="Қара етік")
        self.post(f"/listings/{paused['id']}/pause", self.seller)
        sid = self.c.get("/api/v1/me", headers=self.h(self.seller)).json()["id"]
        self.c.put("/api/v1/me/shop-about", json={"text": "Тек түпнұсқа"}, headers=self.h(self.seller))
        page = self.c.get(f"/s/{sid}").text
        self.assertIn('<meta property="og:title" content="Qadam Store">', page)
        self.assertIn('<meta property="og:description" content="Тек түпнұсқа">', page)
        self.assertIn(f'href="/l/{on_sale["id"]}"', page)
        self.assertIn("Ақ кеды &lt;b&gt;", page)
        self.assertNotIn("Қара етік", page)  # paused listings stay off the page
        self.assertIn("Алматы · 1 тауар", page)
        self.assertIn(f'href="vitrina://open/shop/{sid}"', page)
        self.assertNotIn("+7701", page)
        self.assertIn("Open the shop in the app", self.c.get(f"/s/{sid}?lang=en").text)
        buyer = self.c.get("/api/v1/me", headers=self.h(self.buyer)).json()["id"]
        self.assertEqual(self.c.get(f"/s/{buyer}").status_code, 404)  # not a shop
        self.assertEqual(self.c.get("/s/99999").status_code, 404)


class MediaTests(ApiTestCase):
    external_media = False

    def upload(self, token, data, name="p.jpg", ctype="image/jpeg"):
        return self.c.post("/api/v1/media", files={"file": (name, data, ctype)}, headers=self.h(token))

    def test_upload_strips_metadata_and_applies_rotation(self):
        r = self.upload(self.seller, jpeg(orientation=6, gps=True))
        self.assertEqual(r.status_code, 201, r.text)
        url = r.json()["url"]
        self.assertTrue(url.startswith("http://test/media/"))
        stored = os.path.join(self.cfg.media_dir, url.removeprefix("http://test/media/"))
        with Image.open(stored) as img:
            self.assertEqual(img.size, (600, 800))  # orientation 6 = rotate 90°
            self.assertEqual(len(img.getexif()), 0)  # no GPS, no device data
            self.assertEqual(img.getpixel((300, 400))[0] > 150, True)  # colour kept

    def test_upload_rejects_non_images_small_images_and_buyers(self):
        self.assertEqual(self.upload(self.seller, b"%PDF-1.4 nope", "x.pdf", "application/pdf").status_code, 415)
        self.assertEqual(self.upload(self.seller, jpeg(size=(200, 200))).json()["code"], "image_too_small")
        self.assertEqual(self.upload(self.buyer, jpeg()).status_code, 403)

    def test_listing_accepts_only_uploaded_photos_and_enough_frames(self):
        self.assertEqual(self.post("/listings", self.seller, LISTING).json()["code"], "foreign_media")
        urls = [self.upload(self.seller, jpeg()).json()["url"] for _ in range(4)]
        photos = [{"url": u, "angle": a} for u, a in zip(urls, ("front", "outer", "inner", "back"))]
        frames = [{"url": urls[0], "angle": "frame"}] * 3
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos + frames})
        self.assertEqual(r.json()["code"], "too_few_frames")
        r = self.post("/listings", self.seller, {**LISTING, "photos": photos + frames * 3})
        self.assertEqual(r.status_code, 201, r.text)
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"]
        self.assertEqual([(m["id"], m["status"]) for m in mine], [(r.json()["id"], "draft")])
        served = self.c.get(urls[0].replace("http://test", ""))
        self.assertEqual(served.headers["content-type"], "image/jpeg")


class SocialTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def test_chat_between_buyer_and_seller_only(self):
        listing = self.publish()
        conv = self.post("/conversations", self.buyer, {"listing_id": listing["id"]})
        self.assertEqual(conv.status_code, 201, conv.text)
        cid = conv.json()["id"]
        again = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()
        self.assertEqual(again["id"], cid)  # one thread per buyer and listing
        self.assertEqual(self.post("/conversations", self.seller, {"listing_id": listing["id"]}).status_code, 409)

        self.assertEqual(self.post(f"/conversations/{cid}/messages", self.buyer, {"body": "42 өлшемі бар ма?"}).status_code, 201)
        inbox = self.get("/conversations", self.seller).json()["items"]
        self.assertEqual((inbox[0]["unread"], inbox[0]["role"], inbox[0]["other_name"]), (1, "seller", "Сатып алушы"))
        self.assertNotIn("+7", str(inbox))  # phone numbers never shown
        msgs = self.get(f"/conversations/{cid}/messages", self.seller).json()
        self.assertEqual([m["body"] for m in msgs["items"]], ["42 өлшемі бар ма?"])
        self.assertEqual(self.get("/conversations", self.seller).json()["items"][0]["unread"], 0)

        stranger = self.login("+77010000005")
        self.assertEqual(self.get(f"/conversations/{cid}/messages", stranger).status_code, 404)
        self.assertEqual(self.post(f"/conversations/{cid}/messages", stranger, {"body": "hi"}).status_code, 404)

    def test_either_side_sends_a_clean_photo_in_the_chat(self):
        listing = self.publish()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        send = lambda token, **form: self.c.post(  # noqa: E731
            f"/api/v1/conversations/{cid}/photos", files={"file": ("p.jpg", jpeg(gps=True), "image/jpeg")},
            data=form, headers=self.h(token))
        r = send(self.seller, caption="Табанының жақын фотосы")
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(r.json()["body"], "Табанының жақын фотосы")
        stored = os.path.join(self.cfg.media_dir, r.json()["photo_url"].removeprefix("http://test/media/"))
        with Image.open(stored) as img:
            self.assertEqual(len(img.getexif()), 0)  # no GPS from the sender's phone
        self.assertEqual(send(self.buyer).json()["body"], "")  # a photo alone is a message too
        notes = [n["text"] for n in self.get("/notifications", self.seller).json()["items"]]
        self.assertIn("Жаңа хабарлама: 📷 Фото", notes)
        self.assertEqual(send(self.login("+77010000005")).status_code, 404)
        bad = self.c.post(f"/api/v1/conversations/{cid}/photos", files={"file": ("x.txt", b"hello", "text/plain")},
                          headers=self.h(self.buyer))
        self.assertEqual(bad.json()["code"], "unsupported_media")

    def test_contact_details_are_flagged_and_spam_limited(self):
        listing = self.publish()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        r = self.post(f"/conversations/{cid}/messages", self.seller, {"body": "Жазыңыз +7 701 123 45 67 ватсап"}).json()
        self.assertTrue(r["contact_warning"])
        r = self.post(f"/conversations/{cid}/messages", self.seller, {"body": "Ертең жіберемін"}).json()
        self.assertFalse(r["contact_warning"])
        codes = [self.post(f"/conversations/{cid}/messages", self.buyer, {"body": f"m{i}"}).status_code for i in range(21)]
        self.assertEqual(codes[-1], 429)

    def test_review_only_after_completion_once_with_reply(self):
        listing, order = self.delivered()
        early = self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 5})
        self.assertEqual(early.json()["code"], "review_not_allowed")
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        r = self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 4, "text": "Сапасы жақсы"})
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 1}).status_code, 409)
        self.assertEqual(self.post(f"/orders/{order['id']}/review", self.seller, {"rating": 5}).status_code, 404)
        self.assertEqual(self.post(f"/reviews/{r.json()['id']}/reply", self.buyer, {"text": "x"}).status_code, 404)
        self.assertEqual(self.post(f"/reviews/{r.json()['id']}/reply", self.seller, {"text": "Рақмет!"}).status_code, 200)
        seller = self.c.get(f"/api/v1/listings/{listing['id']}").json()["seller"]
        self.assertEqual((seller["rating"], seller["reviews"]), (4.0, 1))
        page = self.c.get(f"/api/v1/sellers/{seller['id']}/reviews").json()
        self.assertEqual(page["items"][0]["seller_reply"], "Рақмет!")
        self.assertTrue(self.get(f"/orders/{order['id']}", self.buyer).json()["reviewed"])
        kinds = [n["kind"] for n in self.get("/notifications", self.buyer).json()["items"]]
        self.assertIn("review_reply", kinds)

    def test_review_carries_the_buyers_own_photos_only(self):
        listing, order = self.delivered()
        oid = order["id"]
        photo = lambda token: self.c.post(f"/api/v1/orders/{oid}/review/photos", headers=self.h(token),  # noqa: E731
                                          files={"file": ("p.jpg", jpeg(), "image/jpeg")})
        self.assertEqual(photo(self.buyer).json()["code"], "review_not_allowed")  # not confirmed yet
        self.post(f"/orders/{oid}/confirm", self.buyer)
        self.assertEqual(photo(self.seller).status_code, 404)
        urls = [photo(self.buyer).json()["url"] for _ in range(2)]
        seller_photo = self.c.post("/api/v1/media", headers=self.h(self.seller),
                                   files={"file": ("p.jpg", jpeg(), "image/jpeg")}).json()["url"]
        bad = self.post(f"/orders/{oid}/review", self.buyer, {"rating": 5, "photos": [seller_photo]})
        self.assertEqual(bad.json()["code"], "foreign_media")
        four = self.post(f"/orders/{oid}/review", self.buyer, {"rating": 5, "photos": urls * 2})
        self.assertEqual(four.status_code, 422)
        r = self.post(f"/orders/{oid}/review", self.buyer, {"rating": 5, "text": "Суреттегідей", "photos": urls})
        self.assertEqual(r.json()["photos"], urls)
        page = self.c.get(f"/api/v1/sellers/{listing['seller']['id']}/reviews").json()
        self.assertEqual(page["items"][0]["photos"], urls)
        self.assertEqual(photo(self.buyer).json()["code"], "already_reviewed")

    def test_size_fit_sums_up_what_buyers_said_about_the_model(self):
        def completed(i):
            listing, order = self.ordered(key=f"fit{i}")
            self.post(f"/orders/{order['id']}/pay", self.buyer)
            self.pay(order, event_id=f"evt_fit_{i}")
            self.post(f"/orders/{order['id']}/accept", self.seller)
            self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": f"FIT{i}"})
            self.deliver(f"FIT{i}", event_id=f"dlv_fit_{i}")
            self.assertEqual(self.post(f"/orders/{order['id']}/confirm", self.buyer).status_code, 200)
            return listing, order

        fits = ["small", "small", None, "true"]
        for i, fit in enumerate(fits):
            listing, order = completed(i)
            r = self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 5, "fit": fit})
            self.assertEqual(r.json()["fit"], fit)
            # Two answers are not enough to say anything about the shoe.
            expected = None if i < 3 else {"answers": 3, "small": 2, "true": 1, "large": 0}
            self.assertEqual(self.c.get(f"/api/v1/listings/{listing['id']}").json()["size_fit"], expected)
        other = self.publish(model_name="Trail 02")
        self.assertIsNone(self.c.get(f"/api/v1/listings/{other['id']}").json()["size_fit"])
        self.assertEqual(self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 5, "fit": "huge"}).status_code,
                         422)

    def test_order_history_lists_each_step(self):
        _, order = self.delivered()
        detail = self.get(f"/orders/{order['id']}", self.buyer).json()
        self.assertEqual([h["status"] for h in detail["history"]],
                         ["PAYMENT_PENDING", "PAID", "SELLER_ACCEPTED", "SHIPPED", "DELIVERED_PENDING_CONFIRMATION"])

    def test_order_steps_notify_the_other_side(self):
        self.delivered()
        seller_note = self.get("/notifications", self.seller).json()
        buyer_note = self.get("/notifications", self.buyer).json()
        self.assertTrue(any("төленді" in n["text"] for n in seller_note["items"]))
        self.assertTrue(any("жіберілді" in n["text"] and "KZ1" in n["text"] for n in buyer_note["items"]))
        self.assertFalse(any("жіберілді" in n["text"] for n in seller_note["items"]))  # not told about own action
        self.assertTrue(any("отправлен" in n["text_ru"] and "KZ1" in n["text_ru"] for n in buyer_note["items"]))
        self.assertGreater(buyer_note["unread"], 0)
        self.post("/notifications/read-all", self.buyer)
        self.assertEqual(self.get("/notifications", self.buyer).json()["unread"], 0)


def pattern_jpeg(seed: int, size=(800, 600)) -> bytes:
    """A photo with real structure, so its difference hash carries information."""
    import random
    rnd = random.Random(seed)
    img = Image.new("RGB", size, (240, 240, 240))
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    for _ in range(12):
        x, y = rnd.randrange(size[0]), rnd.randrange(size[1])
        d.ellipse((x, y, x + rnd.randrange(80, 300), y + rnd.randrange(60, 200)),
                  fill=tuple(rnd.randrange(256) for _ in range(3)))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=90)
    return out.getvalue()


class ModerationTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def draft(self, token=None, **over):
        r = self.post("/listings", token or self.seller, {**LISTING, **over})
        self.assertEqual(r.status_code, 201, r.text)
        return r.json()["id"]

    def test_clean_listing_is_published_straight_away(self):
        listing = self.publish(description="Бір маусым киілген, таза.")
        self.assertEqual(listing["status"], "published")
        self.assertEqual(listing["moderation"]["flags"], [])

    def test_contacts_and_replica_words_go_to_the_queue_with_reasons(self):
        lid = self.draft(description="Жазыңыз WhatsApp +7 701 123 45 67")
        r = self.post(f"/listings/{lid}/publish", self.seller).json()
        self.assertEqual(r["status"], "moderation")
        self.assertEqual(r["moderation"]["flags"], ["contacts"])
        self.assertIn("чатында", r["moderation"]["reasons"][0])
        lid2 = self.draft(title="Найк люкс копия")
        self.assertEqual(self.post(f"/listings/{lid2}/publish", self.seller).json()["moderation"]["flags"], ["replica"])
        catalog = self.c.get("/api/v1/listings").json()["items"]
        self.assertEqual(catalog, [])  # nothing in the queue is visible to buyers

    def test_staff_approve_or_send_back_and_the_seller_is_told(self):
        lid = self.draft(description="Telegram арқылы жазыңыз")
        self.post(f"/listings/{lid}/publish", self.seller)
        self.assertEqual(self.get("/admin/moderation", self.buyer).status_code, 403)
        staff = self.make_staff()
        queue = self.get("/admin/moderation", staff).json()["items"]
        self.assertEqual([(q["listing"]["id"], q["moderation"]["flags"]) for q in queue], [(lid, ["contacts"])])
        self.assertEqual(self.post(f"/admin/moderation/{lid}/reject", staff, {"reason": "x"}).status_code, 422)
        r = self.post(f"/admin/moderation/{lid}/reject", staff, {"reason": "Сипаттамадан мессенджерді алып тастаңыз"})
        self.assertEqual(r.json()["status"], "rejected")
        mine = self.get(f"/listings/{lid}", self.seller).json()
        self.assertEqual(mine["moderation"]["note"], "Сипаттамадан мессенджерді алып тастаңыз")
        notes = self.get("/notifications", self.seller).json()["items"]
        self.assertEqual((notes[0]["kind"], notes[0]["listing_id"]), ("moderation", lid))
        self.assertIn("қайтарылды", notes[0]["text"])
        # The seller fixes the text; the listing passes the checks on its own.
        self.c.patch(f"/api/v1/listings/{lid}", json={"description": "Жақсы күйде"}, headers=self.h(self.seller))
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["status"], "published")
        # Approving clears the same flag for later republishing.
        lid2 = self.draft(description="www.qadam.kz дүкенімізде көбірек")
        self.post(f"/listings/{lid2}/publish", self.seller)
        self.assertEqual(self.post(f"/admin/moderation/{lid2}/approve", staff).json()["status"], "published")
        self.assertEqual(self.post(f"/admin/moderation/{lid2}/approve", staff).status_code, 409)
        self.post(f"/listings/{lid2}/pause", self.seller)
        self.assertEqual(self.post(f"/listings/{lid2}/publish", self.seller).json()["status"], "published")
        actions = [a["action"] for a in self.get("/admin/audit", staff).json()["items"]]
        self.assertIn("approve_listing", actions)
        self.assertIn("reject_listing", actions)

    def test_adding_a_phone_to_a_live_listing_sends_it_back_to_the_queue(self):
        listing = self.publish()
        r = self.c.patch(f"/api/v1/listings/{listing['id']}", json={"description": "Қоңырау шалыңыз 87011234567"},
                         headers=self.h(self.seller))
        self.assertEqual(r.json()["status"], "moderation")

    def test_a_price_far_below_the_model_is_flagged(self):
        for _ in range(5):
            self.publish()
        lid = self.draft(price_tiyn=900_000)
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["moderation"]["flags"],
                         ["low_price"])
        lid = self.draft(price_tiyn=3_800_000)
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["status"], "published")


class ModerationPhotoTests(ApiTestCase):
    external_media = False

    def upload(self, token, data):
        r = self.c.post("/api/v1/media", files={"file": ("p.jpg", data, "image/jpeg")}, headers=self.h(token))
        self.assertEqual(r.status_code, 201, r.text)
        return r.json()["url"]

    def listing(self, token, seeds):
        photos = [{"url": self.upload(token, pattern_jpeg(s)), "angle": a}
                  for s, a in zip(seeds, ("front", "outer", "inner", "back"))]
        r = self.post("/listings", token, {**LISTING, "photos": photos})
        self.assertEqual(r.status_code, 201, r.text)
        return self.post(f"/listings/{r.json()['id']}/publish", token).json()

    def test_a_photo_taken_from_another_seller_is_flagged(self):
        self.assertEqual(self.listing(self.seller, (1, 2, 3, 4))["status"], "published")
        other = self.login("+77010000003")
        self.post("/me/seller", other, {"shop_name": "Басқа", "city": "Астана"})
        self.assertEqual(self.listing(other, (5, 6, 7, 8))["status"], "published")
        stolen = self.listing(other, (9, 10, 11, 2))  # one photo is the first seller's, re-uploaded
        self.assertEqual(stolen["moderation"]["flags"], ["reused_photo"])
        # Reusing your own photos is fine, and the seller whose photo was copied is never held back.
        self.assertEqual(self.listing(self.seller, (1, 12, 13, 14))["status"], "published")

    def test_a_stolen_photo_added_after_publishing_is_caught_too(self):
        self.assertEqual(self.listing(self.seller, (1, 2, 3, 4))["status"], "published")
        other = self.login("+77010000003")
        self.post("/me/seller", other, {"shop_name": "Басқа", "city": "Астана"})
        lid = self.listing(other, (5, 6, 7, 8))["id"]
        stolen = [{"url": self.upload(other, pattern_jpeg(3)), "angle": "defect"}]
        r = self.c.patch(f"/api/v1/listings/{lid}", json={"add_photos": stolen}, headers=self.h(other))
        self.assertEqual(r.json()["status"], "moderation", r.text)
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][-1]
        r = self.c.patch(f"/api/v1/listings/{mine['id']}", json={"price_tiyn": 4_000_000}, headers=self.h(self.seller))
        self.assertEqual(r.json()["status"], "published")


class OfferTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def offer(self, listing, amount, token=None):
        return self.post(f"/listings/{listing['id']}/offers", token or self.buyer,
                         {"size_id": listing["sizes"][0]["id"], "amount_tiyn": amount})

    def test_todo_counts_what_waits_on_each_side(self):
        listing = self.publish()
        self.assertEqual(self.offer(listing, 4_000_000).status_code, 201)
        self.post(f"/listings/{listing['id']}/questions", self.buyer, {"text": "Өлшемі сай ма?"})
        other = self.publish(title="Екінші")
        self.post("/orders", self.buyer, {"listing_id": other["id"], "size_id": other["sizes"][0]["id"]},
                  **{"Idempotency-Key": "todo"})
        seller = self.get("/me/todo", self.seller).json()
        self.assertEqual((seller["offers"], seller["questions"], seller["to_accept"], seller["to_ship"]), (1, 1, 0, 0))
        buyer = self.get("/me/todo", self.buyer).json()
        self.assertEqual((buyer["to_pay"], buyer["to_confirm"], buyer["offers_answered"]), (1, 0, 0))
        self.assertNotIn("offers", buyer)  # seller lines only for sellers
        # Unread chat messages count on each side until that side opens the chat.
        conv = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()
        self.post(f"/conversations/{conv['id']}/messages", self.buyer, {"body": "Өлшемі сай ма?"})
        self.post(f"/conversations/{conv['id']}/messages", self.buyer, {"body": "Тағы бір сұрақ"})
        todo = lambda t: self.c.get("/api/v1/me/todo", headers=self.h(t)).json()  # noqa: E731
        self.assertEqual((todo(self.seller)["unread_messages"], todo(self.buyer)["unread_messages"]), (2, 0))
        self.c.get(f"/api/v1/conversations/{conv['id']}/messages", headers=self.h(self.seller))
        self.assertEqual(todo(self.seller)["unread_messages"], 0)

    def test_offer_bounds_and_daily_limit(self):
        listing = self.publish()  # 45 000 ₸
        self.assertEqual(self.offer(listing, 4_500_000).json()["code"], "offer_not_lower")
        self.assertEqual(self.offer(listing, 2_000_000).json()["code"], "offer_too_low")
        self.assertEqual(self.offer(listing, 4_000_050).json()["code"], "validation")
        self.assertEqual(self.offer(listing, 4_000_000, self.seller).json()["code"], "own_listing")
        first = self.offer(listing, 3_800_000)
        self.assertEqual(first.status_code, 201, first.text)
        second = self.offer(listing, 3_900_000).json()
        mine = self.get("/offers", self.buyer).json()["items"]
        self.assertEqual([(o["id"], o["status"]) for o in mine],
                         [(second["id"], "pending"), (first.json()["id"], "withdrawn")])
        self.offer(listing, 4_000_000)
        self.assertEqual(self.offer(listing, 4_100_000).json()["code"], "offer_limit")

    def test_accepted_offer_orders_at_the_offer_price_once(self):
        listing = self.publish()
        offer = self.offer(listing, 4_000_000).json()
        seller_view = self.get("/offers?role=seller", self.seller).json()
        self.assertEqual((seller_view["waiting"], seller_view["items"][0]["size_label"]), (1, "EU 42"))
        self.assertEqual(self.post(f"/offers/{offer['id']}/accept", self.buyer).status_code, 409)  # not their turn
        accepted = self.post(f"/offers/{offer['id']}/accept", self.seller).json()
        self.assertEqual((accepted["status"], accepted["price_tiyn"]), ("accepted", 4_000_000))
        note = self.get("/notifications", self.buyer).json()["items"][0]
        self.assertEqual((note["kind"], note["listing_id"]), ("offer_reply", listing["id"]))
        self.assertIn("40 000 ₸", note["text"])
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"], "offer_id": offer["id"]}
        stranger = self.login("+77010000005")
        self.assertEqual(self.post("/orders", stranger, body, **{"Idempotency-Key": "s"}).status_code, 404)
        order = self.post("/orders", self.buyer, body, **{"Idempotency-Key": "o1"}).json()
        self.assertEqual(order["item_price_tiyn"], 4_000_000)
        self.assertEqual(self.get("/offers", self.buyer).json()["items"][0]["status"], "ordered")

    def test_counter_offer_and_expiry(self):
        listing = self.publish()
        offer = self.offer(listing, 3_000_000).json()
        self.assertEqual(self.post(f"/offers/{offer['id']}/counter", self.seller,
                                   {"amount_tiyn": 4_600_000}).json()["code"], "counter_out_of_range")
        self.assertEqual(self.post(f"/offers/{offer['id']}/counter", self.buyer,
                                   {"amount_tiyn": 4_000_000}).status_code, 409)
        countered = self.post(f"/offers/{offer['id']}/counter", self.seller, {"amount_tiyn": 4_000_000}).json()
        self.assertEqual((countered["status"], countered["price_tiyn"]), ("countered", 4_000_000))
        self.assertEqual(self.post(f"/offers/{offer['id']}/accept", self.seller).status_code, 409)
        self.assertEqual(self.post(f"/offers/{offer['id']}/accept", self.buyer).json()["status"], "accepted")
        with self.db() as db:
            row = db.get(Offer, offer["id"])
            row.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
            db.commit()
        self.assertEqual(self.get("/offers", self.buyer).json()["items"][0]["status"], "expired")
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"], "offer_id": offer["id"]}
        self.assertEqual(self.post("/orders", self.buyer, body, **{"Idempotency-Key": "late"}).json()["code"],
                         "offer_not_active")

    def test_declined_offer_tells_the_buyer(self):
        listing = self.publish()
        offer = self.offer(listing, 3_500_000).json()
        self.assertEqual(self.post(f"/offers/{offer['id']}/decline", self.seller).json()["status"], "declined")
        self.assertIn("қабылданбады", self.get("/notifications", self.buyer).json()["items"][0]["text"])
        self.assertEqual(self.post(f"/offers/{offer['id']}/withdraw", self.buyer).status_code, 409)


class SavedSearchTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def test_buyer_is_told_once_when_a_matching_listing_goes_on_sale(self):
        self.assertEqual(self.post("/saved-searches", self.buyer, {}).json()["code"], "validation")
        r = self.post("/saved-searches", self.buyer, {"q": "nike", "size_cm": "26,5", "max_price_tiyn": 5_000_000})
        self.assertEqual(r.status_code, 201, r.text)
        again = self.post("/saved-searches", self.buyer, {"q": " nike ", "size_cm": "26,5", "max_price_tiyn": 5_000_000})
        self.assertEqual(again.json()["id"], r.json()["id"])  # the same search is not stored twice
        self.post("/saved-searches", self.buyer, {"category": "sneakers"})  # also matches; still one notice
        self.publish(price_tiyn=6_000_000)  # too dear
        self.publish(sizes=[{"label": "EU 40", "insole_cm": "25,0", "quantity": 1}])  # wrong size
        self.assertEqual([n["kind"] for n in self.get("/notifications", self.buyer).json()["items"]],
                         ["saved_search", "saved_search"])  # the category-only search matched both
        with self.db() as db:
            for s in db.query(SavedSearch).filter(SavedSearch.category.is_not(None)).all():
                db.delete(s)
            db.commit()
        listing = self.publish()
        notes = self.get("/notifications", self.buyer).json()["items"]
        self.assertEqual((notes[0]["kind"], notes[0]["listing_id"]), ("saved_search", listing["id"]))
        self.assertIn("Күнделікті кроссовка", notes[0]["text"])
        self.assertEqual(self.get("/notifications", self.seller).json()["items"], [])  # never about your own
        self.post(f"/listings/{listing['id']}/pause", self.seller)
        self.post(f"/listings/{listing['id']}/publish", self.seller)
        self.assertEqual(len(self.get("/notifications", self.buyer).json()["items"]), 3)  # not again

    def test_listing_waiting_for_moderation_is_announced_only_when_approved(self):
        self.post("/saved-searches", self.buyer, {"q": "кроссовка"})
        r = self.post("/listings", self.seller, {**LISTING, "description": "WhatsApp 87011234567"})
        self.post(f"/listings/{r.json()['id']}/publish", self.seller)
        self.assertEqual(self.get("/notifications", self.buyer).json()["items"], [])
        self.post(f"/admin/moderation/{r.json()['id']}/approve", self.make_staff())
        self.assertEqual(self.get("/notifications", self.buyer).json()["items"][0]["kind"], "saved_search")

    def test_a_search_for_colours_is_told_only_about_those_colours(self):
        r = self.post("/saved-searches", self.buyer, {"color": "Blue, черный"})
        self.assertEqual((r.status_code, r.json()["color"]), (201, "көк,қара"))
        again = self.post("/saved-searches", self.buyer, {"color": "қара,көк"})
        self.assertEqual(again.json()["id"], r.json()["id"])  # the same colours in other words: one search
        self.publish(color="қызыл")
        self.assertEqual(self.get("/notifications", self.buyer).json()["items"], [])
        blue = self.publish(color="синий")
        two_tone = self.publish(color="бело-черный")  # black is in it
        self.assertEqual([n["listing_id"] for n in self.get("/notifications", self.buyer).json()["items"]],
                         [two_tone["id"], blue["id"]])

    def test_a_colour_list_too_long_once_in_kazakh_is_refused_not_stored(self):
        # "multi" is 5 letters, "түрлі түсті" 11: the length is checked on what would be stored.
        typed = ",".join(["multi", "orange", "кум", "ivory", "navy", "pink"] + [f"x{i:02}" for i in range(67)])
        self.assertLessEqual(len(typed), 300)
        r = self.post("/saved-searches", self.buyer, {"color": typed})
        self.assertEqual((r.status_code, r.json()["code"]), (422, "validation"))

    def test_list_delete_and_limit(self):
        ids = [self.post("/saved-searches", self.buyer, {"q": f"model {i}"}).json()["id"] for i in range(10)]
        self.assertEqual(self.post("/saved-searches", self.buyer, {"q": "one more"}).json()["code"],
                         "saved_search_limit")
        self.assertEqual(self.get("/saved-searches", self.seller).json()["items"], [])
        self.assertEqual(self.c.delete(f"/api/v1/saved-searches/{ids[0]}", headers=self.h(self.seller)).status_code, 404)
        self.assertEqual(self.c.delete(f"/api/v1/saved-searches/{ids[0]}", headers=self.h(self.buyer)).status_code, 204)
        items = self.get("/saved-searches", self.buyer).json()["items"]
        self.assertEqual((len(items), items[0]["q"]), (9, "model 9"))


class SaleTests(ApiTestCase):
    def patch(self, lid, price):
        r = self.c.patch(f"/api/v1/listings/{lid}", json={"price_tiyn": price}, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def test_cut_price_shows_the_real_old_price_for_two_weeks(self):
        listing = self.publish()  # 45 000
        self.assertIsNone(listing["was_price_tiyn"])
        self.assertIsNone(self.patch(listing["id"], 4_400_000)["was_price_tiyn"])  # 2% is not a sale
        self.assertEqual(self.patch(listing["id"], 3_600_000)["was_price_tiyn"], 4_400_000)
        self.assertEqual(self.patch(listing["id"], 3_200_000)["was_price_tiyn"], 4_400_000)  # still the top
        sale = self.c.get("/api/v1/listings?sale=true").json()["items"]
        self.assertEqual([i["id"] for i in sale], [listing["id"]])
        with self.db() as db:
            from vitrina_api.models import Listing
            db.get(Listing, listing["id"]).was_until = datetime.now(timezone.utc) - timedelta(minutes=1)
            db.commit()
        self.assertIsNone(self.c.get(f"/api/v1/listings/{listing['id']}").json()["was_price_tiyn"])
        self.assertEqual(self.c.get("/api/v1/listings?sale=true").json()["items"], [])

    def test_a_price_raised_only_to_be_cut_shows_no_sale(self):
        listing = self.publish()  # 45 000
        self.assertIsNone(self.patch(listing["id"], 6_000_000)["was_price_tiyn"])
        self.assertIsNone(self.patch(listing["id"], 5_000_000)["was_price_tiyn"])  # still above 45 000
        cut = self.patch(listing["id"], 4_000_000)
        self.assertEqual(cut["was_price_tiyn"], 4_500_000)  # the lowest of the month, not the inflated 60 000
        with self.db() as db:
            from vitrina_api.models import PriceChange
            prices = [p.price_tiyn for p in db.query(PriceChange).filter_by(listing_id=listing["id"]).order_by(PriceChange.id)]
        self.assertEqual(prices, [4_500_000, 6_000_000, 5_000_000, 4_000_000])

    def test_prices_older_than_a_month_do_not_count(self):
        listing = self.publish()  # 45 000
        self.patch(listing["id"], 3_000_000)
        with self.db() as db:
            from vitrina_api.models import Listing, PriceChange
            for p in db.query(PriceChange).filter_by(listing_id=listing["id"]):
                p.at = p.at.replace(tzinfo=timezone.utc) - timedelta(days=40) if p.at.tzinfo is None else p.at - timedelta(days=40)
            db.get(Listing, listing["id"]).was_until = None
            db.commit()
        self.patch(listing["id"], 5_000_000)
        # The month before this cut held 30 000 (until the raise) and 50 000: the lowest is 30 000, so no sale.
        self.assertIsNone(self.patch(listing["id"], 4_500_000)["was_price_tiyn"])

    def test_raising_the_price_ends_the_sale(self):
        listing = self.publish()
        self.patch(listing["id"], 3_000_000)
        self.assertIsNone(self.patch(listing["id"], 4_600_000)["was_price_tiyn"])


class AwayTests(ApiTestCase):
    def put(self, path, token, body):
        return self.c.put(f"/api/v1{path}", json=body, headers=self.h(token))

    def test_buyer_sees_in_the_chat_that_the_seller_is_away(self):
        listing = self.publish()
        conv = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()
        self.assertIsNone(conv["seller_away_until"])
        back = (date.today() + timedelta(days=10)).isoformat()
        self.assertEqual(self.put("/me/away", self.seller, {"until": back}).status_code, 200)
        items = self.c.get("/api/v1/conversations", headers=self.h(self.buyer)).json()["items"]
        self.assertEqual(items[0]["seller_away_until"], back)

    def test_holiday_blocks_orders_and_offers_until_the_seller_is_back(self):
        listing = self.publish()
        today = datetime.now(timezone(timedelta(hours=5))).date()
        self.assertEqual(self.put("/me/away", self.buyer, {"until": today.isoformat()}).status_code, 403)
        too_far = (today + timedelta(days=61)).isoformat()
        self.assertEqual(self.put("/me/away", self.seller, {"until": too_far}).json()["code"], "validation")
        back = (today + timedelta(days=7)).isoformat()
        self.assertEqual(self.put("/me/away", self.seller, {"until": back}).json()["away_until"], back)
        shown = self.c.get(f"/api/v1/listings/{listing['id']}").json()
        self.assertEqual(shown["seller"]["away_until"], back)
        self.assertEqual(self.c.get(f"/api/v1/sellers/{shown['seller']['id']}").json()["away_until"], back)
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]}
        self.assertEqual(self.post("/orders", self.buyer, body, **{"Idempotency-Key": "a"}).json()["code"],
                         "seller_away")
        offer = {"size_id": listing["sizes"][0]["id"], "amount_tiyn": 4_000_000}
        self.assertEqual(self.post(f"/listings/{listing['id']}/offers", self.buyer, offer).json()["code"],
                         "seller_away")
        self.assertIsNone(self.put("/me/away", self.seller, {"until": None}).json()["away_until"])
        self.assertEqual(self.post("/orders", self.buyer, body, **{"Idempotency-Key": "b"}).status_code, 201)

    def test_a_past_holiday_no_longer_counts(self):
        listing = self.publish()
        with self.db() as db:
            u = db.query(User).filter_by(phone="+77010000001").one()
            u.away_until = datetime.now(timezone(timedelta(hours=5))).date() - timedelta(days=1)
            db.commit()
        self.assertIsNone(self.c.get(f"/api/v1/listings/{listing['id']}").json()["seller"]["away_until"])


    def test_shop_about_is_shown_on_the_shop_page_without_contacts(self):
        listing = self.publish()
        seller_id = self.c.get(f"/api/v1/listings/{listing['id']}").json()["seller"]["id"]
        about = "Жөнелту 1 күнде. Өлшемі келмесе 3 күн ішінде қайтарамыз."
        self.assertEqual(self.put("/me/shop-about", self.buyer, {"text": about}).json()["code"], "seller_required")
        self.assertEqual(self.put("/me/shop-about", self.seller, {"text": "WhatsApp +7 701 000 00 01"}).json()["code"],
                         "contacts_not_allowed")
        self.assertEqual(self.put("/me/shop-about", self.seller, {"text": "x" * 501}).status_code, 422)
        self.assertEqual(self.put("/me/shop-about", self.seller, {"text": f"  {about} "}).json()["shop_about"], about)
        self.assertEqual(self.c.get(f"/api/v1/sellers/{seller_id}").json()["about"], about)
        self.assertIsNone(self.put("/me/shop-about", self.seller, {"text": "   "}).json()["shop_about"])
        self.assertIsNone(self.c.get(f"/api/v1/sellers/{seller_id}").json()["about"])

    def test_seller_hears_when_a_paid_order_takes_the_last_pair(self):
        sizes = [{"label": "EU 42", "insole_cm": "26,5", "quantity": 1},
                 {"label": "EU 43", "insole_cm": "27,0", "quantity": 2}]
        listing = self.publish(sizes=sizes)
        by_label = {s["label"]: s["id"] for s in listing["sizes"]}

        def buy(label, key):
            r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": by_label[label]},
                          **{"Idempotency-Key": key})
            self.assertEqual(r.status_code, 201, r.text)
            self.post(f"/orders/{r.json()['id']}/pay", self.buyer)
            return r.json()

        def sold_out():
            items = self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
            return [n["text"] for n in items if n["kind"] == "sold_out"]

        first = buy("EU 42", "a")
        self.assertEqual(sold_out(), [])  # not paid yet: it may still be cancelled
        self.assertEqual(self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": by_label["EU 42"]},
                                   **{"Idempotency-Key": "z"}).json()["message_en"], "This size is out of stock.")
        self.assertEqual(self.pay(first, "p1").status_code, 200)
        self.assertEqual(len(sold_out()), 1)
        self.assertIn("EU 42", sold_out()[0])
        self.assertEqual(self.pay(buy("EU 43", "b"), "p2").status_code, 200)
        self.assertEqual(len(sold_out()), 1)  # one pair of 43 is left
        self.assertEqual(self.pay(buy("EU 43", "c"), "p3").status_code, 200)
        self.assertIn("толық сатылды", sold_out()[0])
        items = self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]
        self.assertIn("is sold out", next(n for n in items if n["kind"] == "sold_out")["text_en"])

    def test_shop_sale_cuts_every_listing_and_ending_it_puts_prices_back(self):
        a = self.publish()
        b = self.publish(price_tiyn=1_299_000)
        self.assertEqual(self.post("/me/shop-sale", self.buyer, {"percent": 10}).json()["code"], "seller_required")
        self.assertEqual(self.post("/me/shop-sale", self.seller, {"percent": 80}).status_code, 422)
        self.assertEqual(self.c.post(f"/api/v1/favorites/{a['id']}", headers=self.h(self.buyer)).status_code, 204)
        self.assertEqual(self.post("/me/shop-sale", self.seller, {"percent": 15}).json(), {"changed": 2})
        shown = {i: self.c.get(f"/api/v1/listings/{i}").json() for i in (a["id"], b["id"])}
        self.assertEqual((shown[a["id"]]["price_tiyn"], shown[a["id"]]["was_price_tiyn"]), (3_825_000, 4_500_000))
        self.assertEqual(shown[b["id"]]["price_tiyn"], 1_104_200)  # 11 041,50 ₸ rounded to whole tenge
        kinds = [n["kind"] for n in self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]]
        self.assertEqual(kinds, ["price_drop"])
        self.assertEqual(self.c.delete("/api/v1/me/shop-sale", headers=self.h(self.seller)).json(), {"changed": 2})
        back = self.c.get(f"/api/v1/listings/{a['id']}").json()
        self.assertEqual((back["price_tiyn"], back["was_price_tiyn"]), (4_500_000, None))

    def test_either_side_of_an_order_opens_the_same_chat(self):
        listing = self.publish()
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]},
                      **{"Idempotency-Key": "a"})
        order = r.json()
        from_seller = self.post(f"/orders/{order['id']}/conversation", self.seller).json()
        self.assertEqual((from_seller["role"], from_seller["listing_id"]), ("seller", listing["id"]))
        from_buyer = self.post(f"/orders/{order['id']}/conversation", self.buyer).json()
        self.assertEqual((from_buyer["id"], from_buyer["role"]), (from_seller["id"], "buyer"))
        stranger = self.login("+77010000005")
        self.assertEqual(self.post(f"/orders/{order['id']}/conversation", stranger).status_code, 404)
        self.post(f"/conversations/{from_buyer['id']}/block", self.buyer)
        self.assertEqual(self.post(f"/orders/{order['id']}/conversation", self.seller).json()["code"], "blocked")

class FollowTests(ApiTestCase):
    def test_followers_hear_about_each_new_listing_once(self):
        first = self.publish()
        seller_id = self.c.get(f"/api/v1/listings/{first['id']}").json()["seller"]["id"]
        url = f"/api/v1/sellers/{seller_id}/follow"
        self.assertEqual(self.c.put(url, headers=self.h(self.seller)).json()["code"], "own_shop")
        self.assertEqual(self.c.put(url, headers=self.h(self.buyer)).json(), {"following": True, "followers": 1})
        self.assertEqual(self.c.put(url, headers=self.h(self.buyer)).json()["followers"], 1)  # a second tap
        shop = self.c.get(f"/api/v1/sellers/{seller_id}", headers=self.h(self.buyer)).json()
        self.assertEqual((shop["followers"], shop["following"]), (1, True))
        self.assertFalse(self.c.get(f"/api/v1/sellers/{seller_id}").json()["following"])
        mine = self.c.get("/api/v1/me/following", headers=self.h(self.buyer)).json()["items"]
        self.assertEqual([(m["id"], m["listings"]) for m in mine], [(seller_id, 1)])
        self.assertEqual(self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"], [])
        second = self.publish()
        notes = self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]
        self.assertEqual([(n["kind"], n["listing_id"]) for n in notes], [("followed_shop", second["id"])])
        self.assertEqual(self.c.delete(url, headers=self.h(self.buyer)).json(), {"following": False, "followers": 0})
        self.publish()
        self.assertEqual(len(self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]), 1)

    def test_a_follower_with_a_matching_saved_search_is_told_once(self):
        first = self.publish()
        seller_id = self.c.get(f"/api/v1/listings/{first['id']}").json()["seller"]["id"]
        self.c.put(f"/api/v1/sellers/{seller_id}/follow", headers=self.h(self.buyer))
        self.c.post("/api/v1/saved-searches", json={"category": first["category"]}, headers=self.h(self.buyer))
        self.publish()
        kinds = [n["kind"] for n in self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"]]
        self.assertEqual(kinds, ["followed_shop"])


class ReplyTimeTests(ApiTestCase):
    def test_shop_shows_how_fast_the_seller_usually_answers(self):
        listing = self.publish()
        seller_id = listing["seller"]["id"]
        now = datetime.now(timezone.utc)
        with self.db() as db:
            buyer = db.query(User).filter_by(phone="+77010000002").one()

            conv = Conversation(listing_id=listing["id"], buyer_id=buyer.id, seller_id=seller_id)
            db.add(conv)
            db.flush()
            # Answered in 30 minutes; then two buyer messages answered 50 minutes after the first one.
            for who, minutes_ago in (("b", 300), ("s", 270), ("b", 200), ("b", 190), ("s", 150)):
                db.add(Message(conversation_id=conv.id, sender_id=buyer.id if who == "b" else seller_id, body="?",
                               created_at=now - timedelta(minutes=minutes_ago)))
            db.commit()
        self.assertIsNone(self.c.get(f"/api/v1/sellers/{seller_id}").json()["reply_time"])  # two waits only
        self.make_staff("+77010000005")  # a second user to write from
        with self.db() as db:
            other = db.query(User).filter_by(phone="+77010000005").one()
            conv = Conversation(listing_id=listing["id"], buyer_id=other.id, seller_id=seller_id)
            db.add(conv)
            db.flush()
            db.add(Message(conversation_id=conv.id, sender_id=other.id, body="?",
                           created_at=now - timedelta(hours=30)))  # never answered: counts as a day
            db.commit()
        self.assertEqual(self.c.get(f"/api/v1/sellers/{seller_id}").json()["reply_time"],
                         {"minutes": 50, "bucket": "hour"})


class StockAlertTests(ApiTestCase):
    def notes(self, token):
        return [(n["kind"], n["listing_id"]) for n in
                self.c.get("/api/v1/notifications", headers=self.h(token)).json()["items"]]

    def test_buyer_is_told_once_when_a_sold_out_size_is_back(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 1},
                                      {"label": "EU 43", "insole_cm": "27,5", "quantity": 0}])
        lid = listing["id"]
        s42, s43 = (s["id"] for s in listing["sizes"])
        alert = lambda sid, method="PUT", token=None: self.c.request(  # noqa: E731
            method, f"/api/v1/listings/{lid}/sizes/{sid}/alert", headers=self.h(token or self.buyer))
        self.assertEqual(alert(s42).json()["code"], "in_stock")
        self.assertEqual(alert(s43).json(), {"size_id": s43, "alert": True})
        self.assertEqual(alert(s43).status_code, 200)  # a second tap changes nothing
        shown = self.c.get(f"/api/v1/listings/{lid}", headers=self.h(self.buyer)).json()
        self.assertEqual(shown["stock_alerts"], [s43])
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").json()["stock_alerts"], [])
        self.c.patch(f"/api/v1/listings/{lid}", json={"sizes": [{"id": s43, "quantity": 2}]},
                     headers=self.h(self.seller))
        self.assertEqual(self.notes(self.buyer), [("back_in_stock", lid)])
        self.c.patch(f"/api/v1/listings/{lid}", json={"sizes": [{"id": s43, "quantity": 3}]},
                     headers=self.h(self.seller))
        self.assertEqual(len(self.notes(self.buyer)), 1)  # the alert was used up
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}", headers=self.h(self.buyer)).json()["stock_alerts"], [])

    def test_a_cancelled_order_frees_the_size_for_whoever_was_waiting(self):
        listing, order = self.ordered()  # the only pair: the listing is sold out now
        other = self.login("+77010000004")
        sid = listing["sizes"][0]["id"]
        url = f"/api/v1/listings/{listing['id']}/sizes/{sid}/alert"
        self.assertEqual(self.c.put(url, headers=self.h(other)).status_code, 200)
        self.post(f"/orders/{order['id']}/cancel", self.buyer)
        self.assertEqual(self.notes(other), [("back_in_stock", listing["id"])])
        self.assertEqual(self.c.delete(url, headers=self.h(other)).json(), {"size_id": sid, "alert": False})


class DeliveryTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def test_order_needs_an_address_and_the_seller_sees_it_only_once_paid(self):
        listing = self.publish()
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]}
        missing = self.c.post("/api/v1/orders", json=body, headers=self.h(self.buyer, **{"Idempotency-Key": "x"}))
        self.assertEqual(missing.status_code, 422)
        bad = self.post("/orders", self.buyer, {**body, "delivery": {**ADDRESS, "recipient_phone": "123"}},
                        **{"Idempotency-Key": "y"})
        self.assertEqual(bad.json()["code"], "invalid_phone")
        order = self.post("/orders", self.buyer, {**body, "delivery": {**ADDRESS, "note": "  Домофон 25  "}},
                          **{"Idempotency-Key": "z"}).json()
        mine = self.get(f"/orders/{order['id']}", self.buyer).json()["delivery"]
        self.assertEqual(mine, {"recipient_name": "Айгерім Сапарова", "recipient_phone": "+77010000002",
                                "city": "Алматы", "address": "Абай даңғылы 10, 25-пәтер", "note": "Домофон 25"})
        self.assertIsNone(self.get(f"/orders/{order['id']}", self.seller).json()["delivery"])  # not paid yet
        self.assertEqual(self.get("/me", self.buyer).json()["last_delivery"]["address"], "Абай даңғылы 10, 25-пәтер")
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        self.assertEqual(self.get(f"/orders/{order['id']}", self.seller).json()["delivery"], mine)


class AuthenticityTests(ApiTestCase):
    def upload(self, lid, token):
        return self.c.post(f"/api/v1/listings/{lid}/proofs", headers=self.h(token),
                           files={"file": ("receipt.jpg", jpeg(), "image/jpeg")})

    def test_a_receipt_is_stored_apart_and_shown_only_through_a_link_that_expires(self):
        from vitrina_api.models import AuthProof
        from vitrina_api.storage import private_link
        lid = self.publish()["id"]
        link = self.upload(lid, self.seller).json()["proofs"][0]["url"]
        with self.db() as db:
            stored = db.scalars(select(AuthProof.url)).one()
        self.assertTrue(stored.startswith("private:/"))  # an address never reaches the database
        key = stored.removeprefix("private:/")
        self.assertEqual(self.fetch(link).headers["cache-control"], "private, max-age=3600")
        self.assertEqual(self.c.get(f"/media/{key}").status_code, 404)  # not among the public photos
        tampered = link[:-1] + ("0" if link[-1] != "0" else "1")
        self.assertEqual(self.c.get(tampered.removeprefix("http://test")).status_code, 404)
        old = private_link(self.app.state.private, stored, now=datetime.now(timezone.utc) - timedelta(hours=2))
        self.assertEqual(self.c.get(old.removeprefix("http://test")).status_code, 404)  # expired
        other = link.replace(f"/{key.split('/')[0]}/", "/999/")
        self.assertEqual(self.c.get(other.removeprefix("http://test")).status_code, 404)
        odd = link.split("&sig=")[0] + "&sig=" + "й" * 64  # not hex at all: refused, not a server error
        self.assertEqual(self.c.get(odd.removeprefix("http://test")).status_code, 404)
        # The same address for every answer within a window, so the app's image cache works; valid at least an hour.
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}/proofs", headers=self.h(self.seller)).json()["proofs"][0]
                         ["url"], link)
        at = datetime(2026, 10, 18, 12, 14, 59, tzinfo=timezone.utc)
        same = private_link(self.app.state.private, stored, now=at)
        self.assertEqual(private_link(self.app.state.private, stored, now=at.replace(minute=0, second=0)), same)
        expires = int(same.split("exp=")[1].split("&")[0])
        self.assertGreaterEqual(expires - at.timestamp(), 3600)
        self.assertEqual(private_link(self.app.state.private, "private:/../x.jpg"), "")  # damaged: no file
        # A proof saved before private storage keeps its public address.
        self.assertEqual(private_link(self.app.state.private, "http://test/media/1/" + "a" * 32 + ".jpg"),
                         "http://test/media/1/" + "a" * 32 + ".jpg")

    def test_proof_is_private_and_staff_decide_what_the_listing_shows(self):
        listing = self.publish()
        lid = listing["id"]
        self.assertEqual(self.upload(lid, self.buyer).status_code, 404)
        proofs = self.upload(lid, self.seller).json()
        self.assertEqual((proofs["authenticity"], len(proofs["proofs"])), ("seller_evidence", 1))
        public = self.c.get(f"/api/v1/listings/{lid}").json()
        self.assertEqual(public["authenticity"], "seller_evidence")
        self.assertNotIn(proofs["proofs"][0]["url"], json.dumps(public))  # a receipt never reaches buyers
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}/proofs", headers=self.h(self.buyer)).status_code, 404)
        staff = self.make_staff()
        queue = self.c.get("/api/v1/admin/authenticity", headers=self.h(staff)).json()["items"]
        self.assertEqual([(q["id"], len(q["proofs"])) for q in queue], [(lid, 1)])
        url = f"/api/v1/admin/listings/{lid}/authenticity"
        self.assertEqual(self.c.post(url, json={"value": "documented"}, headers=self.h(self.seller)).status_code, 403)
        self.assertEqual(self.c.post(url, json={"value": "unverified"}, headers=self.h(staff)).json()["code"],
                         "reason_required")
        no = self.c.post(url, json={"value": "unverified", "note": "Чекте модель көрінбейді"}, headers=self.h(staff))
        self.assertEqual((no.json()["authenticity"], no.json()["note"]), ("unverified", "Чекте модель көрінбейді"))
        again = self.upload(lid, self.seller).json()  # a better photo puts it back in the queue
        self.assertEqual((again["authenticity"], again["note"]), ("seller_evidence", None))
        ok = self.c.post(url, json={"value": "documented"}, headers=self.h(staff)).json()
        self.assertEqual(ok["authenticity"], "documented")
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").json()["authenticity"], "documented")
        self.assertEqual(self.c.get("/api/v1/admin/authenticity", headers=self.h(staff)).json()["items"], [])
        kinds = [n["kind"] for n in self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]]
        self.assertEqual(kinds.count("authenticity"), 2)

    def test_removing_the_last_proof_drops_the_claim(self):
        lid = self.publish()["id"]
        for _ in range(4):
            proofs = self.upload(lid, self.seller).json()
        self.assertEqual(self.upload(lid, self.seller).json()["code"], "proof_limit")
        for p in proofs["proofs"]:
            left = self.c.delete(f"/api/v1/listings/{lid}/proofs/{p['id']}", headers=self.h(self.seller)).json()
        self.assertEqual((left["authenticity"], left["proofs"]), ("unverified", []))


class SuggestTests(ApiTestCase):
    def suggest(self, q):
        return [(i["text"], i["kind"], i["count"]) for i in
                self.c.get("/api/v1/search/suggest", params={"q": q}).json()["items"]]

    def test_suggests_brands_and_models_on_sale_in_either_alphabet(self):
        self.publish(brand="Nike", model_name="Air Force 1")
        self.publish(brand="Nike", model_name="Air Force 1")
        self.publish(brand="Nike", model_name="Dunk Low")
        self.publish(brand="New Balance", model_name="574")
        draft = self.post("/listings", self.seller, {**LISTING, "brand": "Nike", "model_name": "Secret"})
        self.assertEqual(draft.status_code, 201)
        self.assertEqual(self.suggest("ni"), [("Nike", "brand", 3), ("Nike Air Force 1", "model", 2),
                                              ("Nike Dunk Low", "model", 1)])
        self.assertEqual(self.suggest("най")[0], ("Nike", "brand", 3))  # half-typed Cyrillic alias
        self.assertEqual(self.suggest("найк dunk"), [("Nike Dunk Low", "model", 1)])
        self.assertEqual(self.suggest("force"), [("Nike Air Force 1", "model", 2)])  # any word of the model
        self.assertEqual(self.suggest("нью"), [("New Balance", "brand", 1), ("New Balance 574", "model", 1)])
        self.assertEqual(self.suggest("n"), [])  # one letter says too little


class DeleteAccountTests(ApiTestCase):
    def test_buyer_deletes_the_account_once_orders_are_done_and_can_start_over(self):
        listing, order = self.ordered()
        self.c.put(f"/api/v1/sellers/{listing['seller']['id']}/follow", headers=self.h(self.buyer))
        self.assertEqual(self.c.delete("/api/v1/me", headers=self.h(self.buyer)).json()["code"], "open_orders")
        self.post(f"/orders/{order['id']}/cancel", self.buyer)
        old_id = self.c.get("/api/v1/me", headers=self.h(self.buyer)).json()["id"]
        self.assertEqual(self.c.delete("/api/v1/me", headers=self.h(self.buyer)).json(), {"deleted": True})
        self.assertEqual(self.c.get("/api/v1/me", headers=self.h(self.buyer)).status_code, 401)  # signed out
        shop = self.c.get(f"/api/v1/sellers/{listing['seller']['id']}").json()
        self.assertEqual(shop["followers"], 0)
        with self.db() as db:
            gone = db.get(User, old_id)
            self.assertTrue(gone.phone.startswith("deleted:"))
            self.assertIsNone(gone.last_delivery)
        fresh = self.login("+77010000002")  # the number is free again: a new, empty account
        self.assertNotEqual(self.c.get("/api/v1/me", headers=self.h(fresh)).json()["id"], old_id)

    def test_a_deleted_shop_leaves_the_catalog(self):
        listing = self.publish()
        self.assertEqual(self.c.delete("/api/v1/me", headers=self.h(self.seller)).status_code, 200)
        self.assertEqual(self.c.get(f"/api/v1/listings/{listing['id']}").status_code, 404)
        self.assertEqual(self.c.get(f"/api/v1/sellers/{listing['seller']['id']}").status_code, 404)
        self.assertEqual(self.c.get("/api/v1/listings").json()["items"], [])


class NotificationSettingsTests(ApiTestCase):
    def test_optional_alerts_can_be_turned_off_but_order_news_always_arrives(self):
        url = "/api/v1/me/notification-settings"
        start = self.c.get(url, headers=self.h(self.buyer)).json()["items"]
        self.assertTrue(all(i["on"] for i in start))
        self.assertEqual(self.c.put(url, json={"order_status": False}, headers=self.h(self.buyer)).status_code, 422)
        off = self.c.put(url, json={"followed_shop": False}, headers=self.h(self.buyer)).json()["items"]
        self.assertEqual([i["kind"] for i in off if not i["on"]], ["followed_shop"])
        first = self.publish()
        self.c.put(f"/api/v1/sellers/{first['seller']['id']}/follow", headers=self.h(self.buyer))
        self.publish()  # a new listing from a followed shop, but that alert is off
        self.assertEqual(self.c.get("/api/v1/notifications", headers=self.h(self.buyer)).json()["items"], [])
        _, order = self.ordered(key="n1")
        self.post(f"/orders/{order['id']}/cancel", self.buyer)  # order news cannot be muted
        kinds = [n["kind"] for n in self.c.get("/api/v1/notifications", headers=self.h(self.seller)).json()["items"]]
        self.assertIn("order_status", kinds)
        on = self.c.put(url, json={"followed_shop": True}, headers=self.h(self.buyer)).json()["items"]
        self.assertTrue(all(i["on"] for i in on))


class PromoCodeTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def order(self, listing, key, code=None, token=None):
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]}
        if code:
            body["promo_code"] = code
        return self.post("/orders", token or self.buyer, body, **{"Idempotency-Key": key})

    def test_seller_code_takes_money_off_the_item_once_per_buyer(self):
        self.assertEqual(self.post("/me/promo-codes", self.buyer, {"code": "KYZ10", "percent": 10}).status_code, 403)
        for bad in ({"code": "KYZ10"}, {"code": "KYZ10", "percent": 10, "amount_tiyn": 100_000},
                    {"code": "KYZ10", "percent": 80}, {"code": "кыз10", "percent": 10},
                    {"code": "KYZ10", "amount_tiyn": 100_050}):
            self.assertEqual(self.post("/me/promo-codes", self.seller, bad).status_code, 422, bad)
        r = self.post("/me/promo-codes", self.seller, {"code": " kyz10 ", "percent": 10, "max_uses": 2})
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(r.json()["code"], "KYZ10")
        self.assertEqual(self.post("/me/promo-codes", self.seller, {"code": "KYZ10", "amount_tiyn": 50_000}).json()["code"],
                         "promo_exists")
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        self.assertEqual(self.get(f"/listings/{listing['id']}/promo?code=NOPE", self.buyer).json()["code"],
                         "promo_not_found")
        preview = self.get(f"/listings/{listing['id']}/promo?code=kyz10", self.buyer).json()
        self.assertEqual(preview, {"code": "KYZ10", "discount_tiyn": 450_000, "item_price_tiyn": 4_050_000,
                                   "total_tiyn": 4_200_000})
        order = self.order(listing, "p1", "kyz10").json()
        self.assertEqual((order["item_price_tiyn"], order["promo_code"], order["promo_discount_tiyn"]),
                         (4_050_000, "KYZ10", 450_000))
        self.assertEqual(self.pay(order).status_code, 200)  # the buyer pays the discounted total
        self.assertEqual(self.order(listing, "p2", "KYZ10").json()["code"], "promo_already_used")
        other = self.login("+77010000003")
        self.assertEqual(self.order(listing, "p3", "KYZ10", other).status_code, 201)
        third = self.login("+77010000004")
        self.assertEqual(self.order(listing, "p4", "KYZ10", third).json()["code"], "promo_used_up")
        codes = self.get("/me/promo-codes", self.seller).json()["items"]
        self.assertEqual((codes[0]["uses"], codes[0]["max_uses"]), (2, 2))

    def test_cancelled_order_gives_the_use_back_and_ended_code_stops(self):
        promo = self.post("/me/promo-codes", self.seller, {"code": "MINUS5000", "amount_tiyn": 500_000,
                                                           "max_uses": 1, "min_price_tiyn": 4_000_000}).json()
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        cheap = self.publish(price_tiyn=3_000_000)
        self.assertEqual(self.order(cheap, "c0", "MINUS5000").json()["code"], "promo_min_price")
        first = self.order(listing, "c1", "MINUS5000").json()
        self.assertEqual(first["item_price_tiyn"], 4_000_000)
        self.post(f"/orders/{first['id']}/cancel", self.buyer)
        again = self.order(listing, "c2", "MINUS5000")
        self.assertEqual(again.status_code, 201, again.text)
        self.assertEqual(self.c.delete(f"/api/v1/me/promo-codes/{promo['id']}", headers=self.h(self.buyer)).status_code,
                         404)
        self.c.delete(f"/api/v1/me/promo-codes/{promo['id']}", headers=self.h(self.seller))
        self.assertEqual(self.get("/me/promo-codes", self.seller).json()["items"], [])
        other = self.login("+77010000003")
        self.assertEqual(self.order(listing, "c3", "MINUS5000", other).json()["code"], "promo_not_found")

    def test_discount_is_at_most_half_and_not_with_an_offer_or_after_its_last_day(self):
        self.post("/me/promo-codes", self.seller, {"code": "HALF", "amount_tiyn": 4_000_000})
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        self.assertEqual(self.get(f"/listings/{listing['id']}/promo?code=HALF", self.buyer).json()["discount_tiyn"],
                         2_250_000)
        offer = self.post(f"/listings/{listing['id']}/offers", self.buyer,
                          {"size_id": listing["sizes"][0]["id"], "amount_tiyn": 4_000_000}).json()
        self.post(f"/offers/{offer['id']}/accept", self.seller)
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"],
                                              "offer_id": offer["id"], "promo_code": "HALF"}, **{"Idempotency-Key": "o1"})
        self.assertEqual(r.json()["code"], "promo_with_offer")
        yesterday = (datetime.now(timezone(timedelta(hours=5))).date() - timedelta(days=1)).isoformat()
        self.assertEqual(self.post("/me/promo-codes", self.seller,
                                   {"code": "OLD1", "percent": 5, "ends_on": yesterday}).status_code, 422)
        with self.db() as db:
            from vitrina_api.models import PromoCode
            db.add(PromoCode(seller_id=listing["seller"]["id"], code="OLD2", percent=5, min_price_tiyn=0,
                             ends_on=date.fromisoformat(yesterday)))
            db.commit()
        self.assertEqual(self.get(f"/listings/{listing['id']}/promo?code=OLD2", self.buyer).json()["code"],
                         "promo_expired")


class QuestionTests(ApiTestCase):
    def get(self, path, token=None):
        return self.c.get(f"/api/v1{path}", headers=self.h(token) if token else {})

    def test_answered_questions_are_public_and_unanswered_ones_stay_private(self):
        listing = self.publish()
        url = f"/listings/{listing['id']}/questions"
        self.assertEqual(self.post(url, self.seller, {"text": "Өлшемі сай ма?"}).json()["code"], "own_listing")
        self.assertEqual(self.post(url, self.buyer, {"text": "WhatsApp жазыңыз +7 701 000 00 00"}).json()["code"],
                         "contacts_not_allowed")
        r = self.post(url, self.buyer, {"text": "Қорабы бар ма?"})
        self.assertEqual(r.status_code, 201, r.text)
        qid = r.json()["id"]
        self.assertEqual(self.get(url).json()["items"], [])  # nobody else sees it before the answer
        self.assertTrue(self.get(url, self.buyer).json()["items"][0]["mine"])
        seller_view = self.get(url, self.seller).json()
        self.assertEqual(seller_view["unanswered"], 1)
        kinds = [n["kind"] for n in self.get("/notifications", self.seller).json()["items"]]
        self.assertIn("question", kinds)
        other = self.login("+77010000003")
        self.assertEqual(self.post(f"/questions/{qid}/answer", other, {"text": "Иә"}).status_code, 404)
        self.assertEqual(self.post(f"/questions/{qid}/answer", self.seller, {"text": "t.me/qadam"}).json()["code"],
                         "contacts_not_allowed")
        self.assertEqual(self.post(f"/questions/{qid}/answer", self.seller, {"text": "Иә, түпнұсқа қорабымен"})
                         .status_code, 200)
        public = self.get(url).json()
        self.assertEqual([(q["text"], q["answer"], q["mine"]) for q in public["items"]],
                         [("Қорабы бар ма?", "Иә, түпнұсқа қорабымен", False)])
        self.assertIsNone(public["unanswered"])
        self.post(f"/questions/{qid}/answer", self.seller, {"text": "Иә, қорабы мен чегі бар"})
        told = [n for n in self.get("/notifications", self.buyer).json()["items"] if n["kind"] == "question_answered"]
        self.assertEqual(len(told), 1)  # a corrected answer is not a second alert
        self.assertEqual(self.c.delete(f"/api/v1/questions/{qid}", headers=self.h(self.buyer)).status_code, 404)
        self.c.delete(f"/api/v1/questions/{qid}", headers=self.h(self.seller))
        self.assertEqual(self.get(url).json()["items"], [])

    def test_a_buyer_waits_for_answers_before_asking_more(self):
        listing = self.publish()
        url = f"/listings/{listing['id']}/questions"
        ids = [self.post(url, self.buyer, {"text": f"Сұрақ нөмірі {i}"}).json()["id"] for i in range(3)]
        self.assertEqual(self.post(url, self.buyer, {"text": "Тағы бір сұрақ"}).json()["code"], "too_many_questions")
        self.c.delete(f"/api/v1/questions/{ids[0]}", headers=self.h(self.buyer))  # takes one back
        self.assertEqual(self.post(url, self.buyer, {"text": "Тағы бір сұрақ"}).status_code, 201)


class SalesExportTests(ApiTestCase):
    def test_seller_downloads_orders_with_promo_commission_and_payout(self):
        self.assertEqual(self.c.get("/api/v1/me/sales.csv", headers=self.h(self.buyer)).status_code, 403)
        self.post("/me/promo-codes", self.seller, {"code": "QADAM10", "percent": 10})
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 3}])
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"],
                                              "promo_code": "QADAM10"}, **{"Idempotency-Key": "s1"})
        order = r.json()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        self.post(f"/orders/{order['id']}/accept", self.seller)
        self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": "KZ9"})
        self.deliver("KZ9")
        self.assertEqual(self.post(f"/orders/{order['id']}/confirm", self.buyer).status_code, 200)
        other = self.login("+77010000003")
        unpaid = self.post("/orders", other, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"],
                                              "delivery": {**ADDRESS, "city": "Шымкент"}},
                           **{"Idempotency-Key": "s2"}).json()
        r = self.c.get("/api/v1/me/sales.csv", headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200)
        self.assertIn("attachment", r.headers["content-disposition"])
        self.assertTrue(r.content.startswith("\ufeff".encode()))
        rows = [line.split(";") for line in r.text.lstrip("\ufeff").strip().split("\r\n")]
        self.assertEqual(rows[0][0], "Тапсырыс")
        done, waiting = rows[1], rows[2]
        self.assertEqual((done[0], done[2], done[5], done[6], done[7], done[8]),
                         (str(order["id"]), "Аяқталды", "40500", "QADAM10", "4500", "1500"))
        self.assertEqual(int(done[9]) + int(done[10]), 40500 + 1500)  # commission and payout split what was paid
        self.assertEqual(done[11], "Алматы")
        self.assertEqual((waiting[0], waiting[9], waiting[10], waiting[11]), (str(unpaid["id"]), "", "", ""))


class BlockTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def test_a_blocked_buyer_cannot_write_offer_ask_or_order_until_unblocked(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 3}])
        conv = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()
        self.post(f"/conversations/{conv['id']}/messages", self.buyer, {"body": "Сәлем"})
        other = self.login("+77010000003")
        self.assertEqual(self.post(f"/conversations/{conv['id']}/block", other).status_code, 404)  # not their chat
        self.assertEqual(self.post(f"/conversations/{conv['id']}/block", self.seller).status_code, 200)
        self.assertEqual(self.get("/conversations", self.seller).json()["items"], [])  # gone from the seller's list
        self.assertEqual(len(self.get("/conversations", self.buyer).json()["items"]), 1)
        size = listing["sizes"][0]["id"]
        for path, body in ((f"/conversations/{conv['id']}/messages", {"body": "Неге?"}),
                           ("/conversations", {"listing_id": listing["id"]}),
                           (f"/listings/{listing['id']}/offers", {"size_id": size, "amount_tiyn": 4_000_000}),
                           (f"/listings/{listing['id']}/questions", {"text": "Өлшемі сай ма?"})):
            r = self.post(path, self.buyer, body)
            self.assertEqual((r.status_code, r.json()["code"]), (403, "blocked"), path)
        r = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": size}, **{"Idempotency-Key": "b1"})
        self.assertEqual(r.json()["code"], "blocked")
        r = self.post(f"/conversations/{conv['id']}/messages", self.seller, {"body": "Кешіріңіз"})
        self.assertEqual(r.json()["code"], "blocked")  # the blocker cannot write either while it lasts
        blocks = self.get("/me/blocks", self.seller).json()["items"]
        self.assertEqual(len(blocks), 1)
        self.assertEqual(self.c.delete(f"/api/v1/me/blocks/{blocks[0]['user_id']}", headers=self.h(self.buyer))
                         .status_code, 404)  # only the blocker lifts it
        self.c.delete(f"/api/v1/me/blocks/{blocks[0]['user_id']}", headers=self.h(self.seller))
        self.assertEqual(self.post(f"/conversations/{conv['id']}/messages", self.buyer, {"body": "Рақмет"}).status_code,
                         201)
        self.assertEqual(len(self.get("/conversations", self.seller).json()["items"]), 1)


class AdminTests(ApiTestCase):
    def test_support_console_page_is_served(self):
        r = self.c.get("/admin/")
        self.assertEqual(r.status_code, 200)
        self.assertIn("/api/v1", r.text)

    def test_admin_views_are_staff_only_and_show_dispute_reasons(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Өлшемі сәйкес емес"})
        for path in ("/admin/overview", "/admin/orders", "/admin/listings", "/admin/audit"):
            self.assertEqual(self.c.get(f"/api/v1{path}", headers=self.h(self.buyer)).status_code, 403, path)
        staff = self.make_staff()
        disputes = self.c.get("/api/v1/admin/orders?status=DISPUTED", headers=self.h(staff)).json()["items"]
        self.assertEqual([d["id"] for d in disputes], [order["id"]])
        self.assertEqual(disputes[0]["history"][-1]["reason"], "Өлшемі сәйкес емес")
        overview = self.c.get("/api/v1/admin/overview", headers=self.h(staff)).json()
        self.assertEqual(overview["orders"], {"DISPUTED": 1})
        self.assertEqual(overview["queues"], {"moderation": 0, "authenticity": 0, "disputes": 1, "reports": 0,
                                              "payouts": 0})
        self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 0, "reason": "Өлшем кестесіне сай", "early": True})
        audit = self.c.get("/api/v1/admin/audit", headers=self.h(staff)).json()["items"]
        self.assertEqual(audit[0]["action"], "resolve_dispute")


class WebhookSecurityTests(ApiTestCase):
    def test_scenario_e_duplicate_and_forged_payments(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.assertEqual(self.pay(order, amount=1).status_code, 409)
        self.assertEqual(self.pay(order, event_id="evt_x", amount=None).json()["status"], "PAID")
        self.assertEqual(self.pay(order, event_id="evt_x").json()["result"], "duplicate")
        # A second, different capture is real money: it is owed back to the buyer, never dropped.
        self.assertEqual(self.pay(order, event_id="evt_y").json()["result"], "overpayment")
        self.assertEqual(self.pay(order, event_id="evt_y").json()["result"], "duplicate")
        with self.db() as db:
            self.assertEqual(balance(db, escrow(str(order["id"]))), order["total_tiyn"])
            buyer_id = db.query(User).filter_by(phone="+77010000002").one().id
            self.assertEqual(balance(db, buyer_refund(str(buyer_id))), order["total_tiyn"])

    def test_unsigned_or_stale_webhooks_rejected(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        event = {"id": "e1", "type": "payment.succeeded", "order_id": order["id"],
                 "amount_tiyn": order["total_tiyn"], "currency": "KZT"}
        self.assertEqual(self.hook("payments/sandbox", self.cfg.payment_webhook_secret, event, sig="0" * 64).status_code, 401)
        self.assertEqual(self.hook("payments/sandbox", self.cfg.payment_webhook_secret, event,
                                   ts=int(time.time()) - 3600).status_code, 401)
        self.assertEqual(self.hook("payments/sandbox", b"wrong-secret", event).status_code, 401)
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["status"],
                         "PAYMENT_PENDING")

    def test_buyer_cannot_confirm_unpaid_order(self):
        _, order = self.ordered()
        self.assertEqual(self.post(f"/orders/{order['id']}/confirm", self.buyer).json()["code"], "invalid_transition")


class AuditFixTests(ApiTestCase):
    """Fixes from the 10-expert audit: orders never stall, money is never dropped, and the edges are guarded."""

    def shipped(self, tracking="KZ1", key="k1"):
        listing, order = self.ordered(key)
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order, event_id=f"evt_{key}")
        self.post(f"/orders/{order['id']}/accept", self.seller)
        r = self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": tracking})
        self.assertEqual(r.status_code, 200, r.text)
        return listing, order

    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def later(self, **delta):
        return datetime.now(timezone.utc) + timedelta(**delta)

    def test_buyer_can_say_received_without_a_courier_event_and_sees_the_window(self):
        _, order = self.shipped()
        self.assertEqual(self.post(f"/orders/{order['id']}/received", self.seller).status_code, 404)
        got = self.post(f"/orders/{order['id']}/received", self.buyer).json()
        self.assertEqual(got["status"], "DELIVERED_PENDING_CONFIRMATION")
        detail = self.get(f"/orders/{order['id']}", self.buyer).json()
        until = datetime.fromisoformat(detail["deadline"])
        self.assertGreater(until, self.later(days=4, hours=23))
        self.assertLess(until, self.later(days=5, hours=1))

    def test_accepted_order_that_never_ships_is_refunded_and_restocked(self):
        listing, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        self.post(f"/orders/{order['id']}/accept", self.seller)
        self.assertIsNotNone(self.get(f"/orders/{order['id']}", self.buyer).json()["deadline"])
        with self.db() as db:
            self.assertEqual(run_expire_orders(db, now=self.later(days=4))["refunded"], [])
        with self.db() as db:
            self.assertEqual(run_expire_orders(db, now=self.later(days=6))["refunded"], [order["id"]])
        self.assertEqual(self.get(f"/orders/{order['id']}", self.buyer).json()["status"], "REFUND_PENDING")
        self.assertTrue(self.c.get(f"/api/v1/listings/{listing['id']}").json()["sizes"][0]["available"])

    def test_parcel_with_no_news_and_unanswered_return_go_to_support(self):
        _, lost = self.shipped("KZ-LOST", key="a")
        listing, order = self.delivered_second()
        self.assertEqual(self.post(f"/orders/{order['id']}/return", self.buyer, {"reason": "Өлшемі сай емес"})
                         .json()["status"], "RETURN_REQUESTED")
        with self.db() as db:
            out = run_expire_orders(db, now=self.later(days=22))
        self.assertEqual(sorted(out["disputed"]), sorted([lost["id"], order["id"]]))
        self.assertEqual(self.get(f"/orders/{lost['id']}", self.buyer).json()["status"], "DISPUTED")

    def delivered_second(self):
        listing, order = self.shipped("KZ-2", key="b")
        self.assertEqual(self.deliver("KZ-2", event_id="d2").json()["status"], "DELIVERED_PENDING_CONFIRMATION")
        return listing, order

    def test_return_can_be_contested_by_the_seller_but_not_declined_into_a_refund(self):
        listing, order = self.delivered()
        self.post(f"/orders/{order['id']}/return", self.buyer, {"reason": "Өлшемі сай емес"})
        declined = self.post(f"/orders/{order['id']}/decline", self.seller, {"reason": "жоқ"})
        self.assertEqual(declined.json()["code"], "invalid_status")
        self.assertFalse(self.c.get(f"/api/v1/listings/{listing['id']}").json()["sizes"][0]["available"])
        self.assertEqual(self.post(f"/orders/{order['id']}/dispute", self.seller, {"reason": ""}).status_code, 422)
        got = self.post(f"/orders/{order['id']}/dispute", self.seller, {"reason": "Аяқ киім киілген"})
        self.assertEqual(got.json()["status"], "DISPUTED")

    def test_buyer_escalates_an_ignored_return(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/return", self.buyer, {"reason": "Ақау бар"})
        self.assertEqual(self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Сатушы жауап бермейді"})
                         .json()["status"], "DISPUTED")

    def test_support_resolves_only_disputes(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        staff = self.make_staff()
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 100_000, "reason": "x"})
        self.assertEqual(r.json()["code"], "invalid_status")

    def test_tracking_number_cannot_be_reused_and_repeat_delivery_news_is_harmless(self):
        self.shipped("KZ-SAME", key="a")
        listing, order = self.ordered("b")
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order, event_id="evt_b")
        self.post(f"/orders/{order['id']}/accept", self.seller)
        r = self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": "KZ-SAME"})
        self.assertEqual(r.json()["code"], "tracking_in_use")
        self.assertEqual(self.deliver("KZ-SAME", event_id="x1").json()["status"], "DELIVERED_PENDING_CONFIRMATION")
        self.assertEqual(self.deliver("KZ-SAME", event_id="x2").status_code, 404)  # no parcel on its way any more

    def test_support_sees_the_chat_and_can_mark_delivered(self):
        listing, order = self.shipped()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        self.post(f"/conversations/{cid}/messages", self.buyer, {"body": "Посылка келмеді"})
        staff = self.make_staff()
        self.assertEqual(self.get(f"/admin/orders/{order['id']}/evidence", self.buyer).status_code, 403)
        ev = self.get(f"/admin/orders/{order['id']}/evidence", staff).json()
        self.assertEqual((ev["tracking_number"], ev["messages"][0]["from"], ev["messages"][0]["body"]),
                         ("KZ1", "buyer", "Посылка келмеді"))
        self.assertEqual(self.post(f"/admin/orders/{order['id']}/delivered", staff, {"reason": ""}).status_code, 422)
        done = self.post(f"/admin/orders/{order['id']}/delivered", staff, {"reason": "Курьер қолхатты жіберді"})
        self.assertEqual(done.json()["status"], "DELIVERED_PENDING_CONFIRMATION")
        with self.db() as db:
            from vitrina_api.models import AuditLog
            actions = [a.action for a in db.query(AuditLog).all()]
        self.assertIn("view_evidence", actions)
        self.assertIn("mark_delivered", actions)

    def test_hidden_listing_can_be_given_back_as_a_draft(self):
        listing = self.publish()
        staff = self.make_staff()
        self.post(f"/admin/listings/{listing['id']}/hide", staff, {"reason": "Шағым"})
        self.assertEqual(self.post(f"/admin/listings/{listing['id']}/unhide", self.seller, {"reason": "x"}).status_code, 403)
        r = self.post(f"/admin/listings/{listing['id']}/unhide", staff, {"reason": "Шағым расталмады"})
        self.assertEqual(r.json()["status"], "draft")

    def test_logout_ends_the_session_on_the_server_and_staff_tokens_are_short(self):
        self.assertEqual(self.post("/auth/logout", self.buyer).json(), {"ok": True})
        self.assertEqual(self.get("/me", self.buyer).status_code, 401)
        other = self.login("+77010000002")
        third = self.login("+77010000002")
        self.post("/auth/logout?everywhere=true", other)
        self.assertEqual(self.get("/me", third).status_code, 401)
        self.make_staff()
        staff = self.login("+77010000009")
        with self.db() as db:
            from vitrina_api.models import AuthToken
            from vitrina_api.services import aware
            newest = db.query(AuthToken).order_by(AuthToken.id.desc()).first()
            self.assertLess(aware(newest.expires_at), self.later(hours=13))
        self.assertEqual(self.get("/me", staff).status_code, 200)

    def test_wrong_codes_are_capped_per_day_not_only_per_code(self):
        phone = "+77010000055"
        for _ in range(3):
            self.c.post("/api/v1/auth/otp", json={"phone": phone})
            for _ in range(5):
                self.c.post("/api/v1/auth/verify", json={"phone": phone, "code": "000000"})
        self.assertEqual(self.c.post("/api/v1/auth/otp", json={"phone": phone}).json()["code"], "rate_limited")

    def test_unexpected_errors_answer_in_the_usual_shape_and_big_bodies_are_refused(self):
        def boom():
            raise RuntimeError("database went away")
        self.app.add_api_route("/api/v1/boom", boom)
        c = TestClient(self.app, raise_server_exceptions=False)
        r = c.get("/api/v1/boom")
        self.assertEqual((r.status_code, r.json()["code"]), (503, "unavailable"))
        self.assertTrue(r.headers["X-Request-ID"])
        big = c.post("/api/v1/media", content=b"x", headers={**self.h(self.seller), "Content-Length": str(50 * 1024 * 1024)})
        self.assertEqual(big.status_code, 413)
        admin = c.get("/admin/")
        self.assertEqual(admin.headers["X-Frame-Options"], "DENY")
        self.assertIn("frame-ancestors 'none'", admin.headers["Content-Security-Policy"])

    def test_share_page_never_closes_its_script_early(self):
        evil = "https://cdn.example/x.jpg</script><script>alert(1)</script>"
        frames = [{"url": evil if i == 0 else f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(8)]
        listing = self.publish(photos=LISTING["photos"] + frames)
        page = self.c.get(f"/l/{listing['id']}").text
        self.assertNotIn("</script><script>alert(1)", page)

    def shared_turn(self, page):
        small = json.loads(re.search(r"const small = (\[.*?\]), full", page).group(1))
        full = json.loads(re.search(r"full = (\[.*?\]), img", page).group(1))
        return small, full, re.search(r'id="shot"[^>]* src="([^"]+)"', page).group(1)

    def test_share_page_turns_as_the_app_does_from_the_cover_light_on_data(self):
        frames = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(12)]
        listing = self.publish(photos=LISTING["photos"] + frames)
        from vitrina_api.models import Listing
        with self.app.state.sessions() as db:
            row = db.get(Listing, listing["id"])
            for m in row.media:
                if m.angle == "frame":
                    n = m.original_url.rsplit("/f", 1)[1].split(".")[0]
                    m.processed_url, m.thumb_url = f"https://cdn.example/c{n}.webp", f"https://cdn.example/t{n}.webp"
            row.cover_frame = "https://cdn.example/f7.jpg"
            row.cover_frame_of = next(m.original_url for m in sorted(row.media, key=lambda m: m.position))
            db.commit()
        page = self.c.get(f"/l/{listing['id']}").text
        small, full, first = self.shared_turn(page)
        # From the frame matching the cover, small copies to turn through, full cut-outs at rest.
        self.assertEqual(small[:2], ["https://cdn.example/t7.webp", "https://cdn.example/t8.webp"])
        self.assertEqual(full[-1], "https://cdn.example/c6.webp")
        self.assertEqual((len(small), first), (12, "https://cdn.example/c7.webp"))
        self.assertIn("prefers-reduced-motion", page)
        # One frame without its cut-out: the turn shows the photos as taken, as the app does.
        with self.app.state.sessions() as db:
            next(m for m in db.get(Listing, listing["id"]).media if m.angle == "frame").processed_url = None
            db.commit()
        small, full, _ = self.shared_turn(self.c.get(f"/l/{listing['id']}").text)
        self.assertEqual((small[0], full[0]), ("https://cdn.example/f7.jpg", "https://cdn.example/f7.jpg"))
        self.assertEqual(small[-1], "https://cdn.example/f6.jpg")

    def test_share_page_turns_a_scan_through_its_turn_only(self):
        frames = [{"url": f"https://cdn.example/s{i}.jpg", "angle": "frame"} for i in range(16)]
        stops = [{"url": "https://cdn.example/s10.jpg", "angle": "top"}, {"url": "https://cdn.example/s13.jpg",
                                                                          "angle": "sole"}]
        listing = self.publish(photos=PHOTOS[:4] + stops + frames)  # no separate sole photo
        small, full, first = self.shared_turn(self.c.get(f"/l/{listing['id']}").text)
        self.assertEqual(len(small), 10)  # up to where the camera rises over the top
        self.assertEqual((first, full[-1]), ("https://cdn.example/s0.jpg", "https://cdn.example/s9.jpg"))

    def test_share_page_turn_edges_match_the_app(self):
        from vitrina_api.models import Listing
        from vitrina_api.share import turn_shots
        frames = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(10)]
        frames += [{"url": "https://cdn.example/f0.jpg", "angle": "frame"}]  # the first frame comes round again
        listing = self.publish(photos=LISTING["photos"] + [{"url": "https://cdn.example/top.jpg", "angle": "top"}]
                               + frames)
        page = self.c.get(f"/l/{listing['id']}").text
        small, full, _ = self.shared_turn(page)
        self.assertEqual(len(small), 10)
        # Dragging right turns back, as a finger does in the app; no small copies means no turn on its own.
        self.assertIn("show(k0 - Math.round(", page)
        self.assertIn("light = false", page)
        self.assertEqual(small, full)
        with self.app.state.sessions() as db:
            row = db.get(Listing, listing["id"])
            media = sorted(row.media, key=lambda m: m.position)
            turn = [m for m in media if m.angle == "frame"]
            top, sole = (next(m for m in media if m.angle == a) for a in ("top", "sole"))
            # Stops out of order, or a stop at the first frame, are not a scan: the whole turn from the cover.
            top.original_url, sole.original_url = turn[6].original_url, turn[3].original_url
            self.assertEqual(len(turn_shots(row, media)[0]), 10)
            top.original_url, sole.original_url = turn[0].original_url, turn[4].original_url
            self.assertEqual(len(turn_shots(row, media)[0]), 10)
            # A scan starts where the camera did, whatever frame the cover matches.
            top.original_url, sole.original_url = turn[5].original_url, turn[7].original_url
            row.cover_frame, row.cover_frame_of = turn[3].original_url, next(m for m in media
                                                                             if m.angle != "frame").original_url
            shots = turn_shots(row, media)[0]
            self.assertEqual((len(shots), shots[0][1]), (5, "https://cdn.example/f0.jpg"))
            db.rollback()

    def test_share_page_cut_turn_stands_on_the_apps_stage(self):
        from vitrina_api.models import Listing
        frames = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(8)]
        listing = self.publish(photos=LISTING["photos"] + frames)
        with self.app.state.sessions() as db:
            row = db.get(Listing, listing["id"])
            for m in row.media:
                if m.angle == "frame":
                    m.processed_url, m.thumb_url = m.original_url + "?cut", m.original_url + "?small"
            row.backdrop = "dark"
            db.commit()
        page = self.c.get(f"/l/{listing['id']}").text
        self.assertIn("#0e0e14", page)
        self.assertIn("light = true", page)

    def test_sales_file_never_runs_a_formula_typed_by_a_buyer(self):
        listing = self.publish()
        address = {**ADDRESS, "city": '=HYPERLINK("http://evil/","Алматы")'}
        order = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"],
                                                  "delivery": address}, **{"Idempotency-Key": "f"}).json()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        text = self.c.get("/api/v1/me/sales.csv", headers=self.h(self.seller)).text
        self.assertIn(";'=HYPERLINK", text.replace('"', ''))

    def test_ending_a_sale_puts_back_a_price_raised_this_month(self):
        listing = self.publish(price_tiyn=1_800_000)
        r = self.c.patch(f"/api/v1/listings/{listing['id']}", json={"price_tiyn": 2_000_000}, headers=self.h(self.seller))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.post("/me/shop-sale", self.seller, {"percent": 10}).json(), {"changed": 1})
        self.assertEqual(self.c.delete("/api/v1/me/shop-sale", headers=self.h(self.seller)).json(), {"changed": 1})
        self.assertEqual(self.c.get(f"/api/v1/listings/{listing['id']}").json()["price_tiyn"], 2_000_000)

    def test_purge_drops_old_codes_and_dead_tokens(self):
        from vitrina_api.services import run_purge
        with self.db() as db:
            done = run_purge(db, now=self.later(days=40))
        self.assertTrue(any(x.startswith("otp_codes:") for x in done))
        self.assertTrue(any(x.startswith("auth_tokens:") for x in done))


class ForeignMediaTests(ApiTestCase):
    external_media = False

    def test_listing_photos_must_be_this_sellers_own_uploads(self):
        own = "http://test/media/{}/" + "a" * 32 + ".jpg"
        with self.db() as db:
            seller_id = db.query(User).filter_by(phone="+77010000001").one().id
        for url in ("http://test/media/9/x.jpg</script><script>alert(1)</script>", own.format(seller_id + 100),
                    "http://test/media/" + str(seller_id) + "/../../etc/passwd"):
            r = self.post("/listings", self.seller, {**LISTING, "photos": [{"url": url, "angle": "front"}]})
            self.assertEqual(r.json()["code"], "foreign_media", url)


class ListingEditTests(ApiTestCase):
    """Stage 2: a seller fixes and improves a listing instead of duplicating it and losing its history."""

    def patch(self, lid, body, token=None):
        return self.c.patch(f"/api/v1/listings/{lid}", json=body, headers=self.h(token or self.seller))

    def draft(self, **over):
        r = self.post("/listings", self.seller, {**LISTING, **over})
        self.assertEqual(r.status_code, 201, r.text)
        return r.json()

    def test_a_draft_can_change_everything_and_search_finds_the_new_name(self):
        lid = self.draft()["id"]
        photos = [{"url": f"https://cdn.example/n{i}.jpg", "angle": a} for i, a in
                  enumerate(["front", "outer", "inner", "back", "sole", "label"])]
        r = self.patch(lid, {"title": "Adidas Samba OG", "brand": "Adidas", "category": "sneakers",
                             "condition": "new_with_box", "photos": photos})
        self.assertEqual(r.status_code, 200, r.text)
        got = r.json()
        self.assertEqual((got["title"], got["condition"], len(got["media"])), ("Adidas Samba OG", "new_with_box", 6))
        self.assertEqual(got["media"][0]["original_url"], "https://cdn.example/n0.jpg")
        self.assertEqual(self.post(f"/listings/{lid}/publish", self.seller).json()["status"], "published")
        found = self.c.get("/api/v1/listings", params={"q": "samba"}).json()["items"]
        self.assertEqual([i["id"] for i in found], [lid])

    def test_a_listing_on_sale_keeps_its_shoe_but_gains_photos_a_spin_and_sizes(self):
        listing = self.publish()
        lid = listing["id"]
        for locked in ({"condition": "new_with_box"}, {"category": "casual"}):
            self.assertEqual(self.patch(lid, locked).json()["code"], "listing_locked")
        few = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(5)]
        self.assertEqual(self.patch(lid, {"add_photos": few}).json()["code"], "too_few_frames")
        spin = [{"url": f"https://cdn.example/f{i}.jpg", "angle": "frame"} for i in range(8)]
        r = self.patch(lid, {"add_photos": spin + [{"url": "https://cdn.example/top.jpg", "angle": "top"}],
                             "add_sizes": [{"label": "EU 43", "insole_cm": "27,5", "quantity": 2}],
                             "title": "Күнделікті кроссовка Найк"})
        self.assertEqual(r.status_code, 200, r.text)
        got = r.json()
        self.assertEqual(got["status"], "published")
        self.assertEqual(sum(m["angle"] == "frame" for m in got["media"]), 8)
        self.assertEqual(got["media"][0]["original_url"], PHOTOS[0]["url"])  # what buyers saw is still first
        self.assertEqual([s["label"] for s in got["sizes"]], ["EU 42", "EU 43"])
        self.assertEqual(self.patch(lid, {"add_photos": spin}).status_code, 200)  # a retry adds nothing twice
        self.assertEqual(sum(m["angle"] == "frame" for m in self.patch(lid, {}).json()["media"]), 8)
        other = [{"url": f"https://cdn.example/g{i}.jpg", "angle": "frame"} for i in range(8)]
        self.assertEqual(self.patch(lid, {"add_photos": other}).json()["code"], "frames_exist")
        for locked in ({"brand": "Adidas"}, {"model_name": "Samba"}):
            self.assertEqual(self.patch(lid, locked).json()["code"], "listing_locked")
        self.assertEqual(self.patch(lid, {"title": "  ab  "}).status_code, 422)
        self.assertEqual(self.patch(lid, {"add_sizes": [{"label": "eu 43", "insole_cm": "27,5", "quantity": 1}]})
                         .json()["code"], "size_exists")
        self.assertEqual(self.patch(lid, {"title": "x"}).status_code, 422)
        self.assertEqual(self.patch(lid, {"title": "Басқа"}, token=self.buyer).status_code, 404)

    def test_a_new_name_with_a_phone_number_goes_back_to_review(self):
        lid = self.publish()["id"]
        got = self.patch(lid, {"title": "Кроссовка, жазыңыз 87011234567"}).json()
        self.assertEqual(got["status"], "moderation")

    def test_a_sold_out_listing_with_a_new_size_comes_back_paused(self):
        listing, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        lid = listing["id"]
        self.assertEqual(self.c.get(f"/api/v1/listings/{lid}").json()["status"], "sold")
        got = self.patch(lid, {"add_sizes": [{"label": "EU 41", "insole_cm": "26", "quantity": 1}]}).json()
        self.assertEqual(got["status"], "paused")

    def test_a_condition_can_be_marked_worse_after_sale_but_never_better(self):
        lid = self.publish()["id"]
        r = self.patch(lid, {"condition": "used_good", "defects": "Ұлтанында кішкене сызат бар"})
        self.assertEqual(r.json().get("condition"), "used_good", r.text)
        self.assertEqual(self.patch(lid, {"condition": "used_excellent"}).json()["code"], "listing_locked")
        self.assertEqual(self.patch(lid, {"condition": "defective"}).json()["code"], "defects_required")

    def test_a_rejected_listing_that_was_on_sale_stays_the_same_shoe(self):
        lid = self.publish()["id"]
        self.assertEqual(self.patch(lid, {"title": "Кроссовка, жазыңыз 87011234567"}).json()["status"], "moderation")
        staff = self.make_staff()
        self.assertEqual(self.post(f"/admin/moderation/{lid}/reject", staff, {"reason": "Телефон жазылған"})
                         .json()["status"], "rejected")
        for locked in ({"brand": "Adidas"}, {"category": "casual"}):
            self.assertEqual(self.patch(lid, locked).json()["code"], "listing_locked")
        got = self.patch(lid, {"title": "Күнделікті кроссовка"}).json()
        self.assertEqual(got["status"], "rejected")  # a clean edit goes back through publish, not straight on sale
        self.assertTrue(got["ever_on_sale"])

    def test_a_listing_waiting_for_review_is_not_put_on_sale_by_a_clean_edit(self):
        lid = self.publish()["id"]
        self.patch(lid, {"title": "Кроссовка, жазыңыз 87011234567"})
        self.assertEqual(self.patch(lid, {"title": "Күнделікті кроссовка"}).json()["status"], "moderation")
        self.assertEqual(self.patch(lid, {"sizes": []}).json()["status"], "moderation")

    def test_a_paused_listing_is_checked_too(self):
        lid = self.publish()["id"]
        self.post(f"/listings/{lid}/pause", self.seller)
        got = self.patch(lid, {"title": "Кроссовка, жазыңыз 87011234567"}).json()
        self.assertEqual(got["status"], "moderation")
        from vitrina_api.models import AuditLog
        with self.db() as db:
            self.assertIn("edit_listing", [a.action for a in db.query(AuditLog).all()])

    def test_removing_one_photo_keeps_the_rest_as_they_were(self):
        from vitrina_api.models import Listing
        lid = self.draft()["id"]
        with self.db() as db:
            before = {m.original_url: m.id for m in db.get(Listing, lid).media}
        got = self.patch(lid, {"photos": PHOTOS[:4] + [{"url": "https://cdn.example/new.jpg", "angle": "sole"}]})
        self.assertEqual(got.status_code, 200, got.text)
        with self.db() as db:
            after = {m.original_url: m.id for m in db.get(Listing, lid).media}
        self.assertEqual([after[p["url"]] for p in PHOTOS[:4]], [before[p["url"]] for p in PHOTOS[:4]])
        self.assertNotIn(PHOTOS[4]["url"], after)

    def test_an_order_keeps_the_name_the_buyer_bought(self):
        listing, order = self.ordered()
        self.patch(listing["id"], {"title": "Жаңа атау, басқа аяқ киім"})
        got = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()
        self.assertEqual(got["listing_title"], listing["title"])

    def test_the_seller_may_replace_photos_but_each_order_keeps_what_the_buyer_saw(self):
        listing, order = self.ordered()
        lid = listing["id"]
        new = [{"url": f"https://cdn.example/new{i}.jpg", "angle": a}
               for i, a in enumerate(["front", "outer", "inner", "back"])]
        self.assertEqual(self.patch(lid, {"photos": new[:3]}).json()["code"], "photo_set_incomplete")
        got = self.patch(lid, {"photos": new})
        self.assertEqual(got.status_code, 200, got.text)
        self.assertEqual([m["original_url"] for m in got.json()["media"]], [p["url"] for p in new])
        for token in (self.buyer, self.seller):
            seen = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(token)).json()["listing_photos"]
            self.assertEqual([p["original_url"] for p in seen], [p["url"] for p in PHOTOS])
        staff = self.make_staff()
        evidence = self.c.get(f"/api/v1/admin/orders/{order['id']}/evidence", headers=self.h(staff)).json()
        self.assertEqual(len(evidence["listing_photos"]), len(PHOTOS))

    def test_an_order_from_photos_the_buyer_did_not_see_is_refused(self):
        listing = self.publish()
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"], "photos_version": "0" * 16}
        r = self.post("/orders", self.buyer, body, **{"Idempotency-Key": "pv1"})
        self.assertEqual((r.status_code, r.json()["code"]), (409, "photos_changed"))
        body["photos_version"] = listing["photos_version"]
        self.assertEqual(self.post("/orders", self.buyer, body, **{"Idempotency-Key": "pv2"}).status_code, 201)

    def test_a_replacement_keeps_the_main_sides_and_the_defect_close_ups(self):
        with_defect = PHOTOS + [{"url": "https://cdn.example/d1.jpg", "angle": "defect"}]
        lid = self.publish(condition="used_good", defects="Ұлтанында сызат", photos=with_defect)["id"]
        no_back = [p for p in with_defect if p["angle"] != "back"] + [{"url": "https://cdn.example/t.jpg", "angle": "top"}]
        self.assertEqual(self.patch(lid, {"photos": no_back}).json()["code"], "photo_set_incomplete")
        self.assertEqual(self.patch(lid, {"photos": PHOTOS}).json()["code"], "photo_set_incomplete")
        better = PHOTOS + [{"url": "https://cdn.example/d2.jpg", "angle": "defect"}]
        self.assertEqual(self.patch(lid, {"photos": better}).status_code, 200)

    def test_reported_photos_stay_until_staff_have_looked(self):
        lid = self.publish()["id"]
        self.post(f"/listings/{lid}/report", self.buyer, {"reason": "wrong_photos", "text": "Басқа аяқ киім"})
        new = [{**p, "url": p["url"].replace("/p", "/q")} for p in PHOTOS]
        self.assertEqual(self.patch(lid, {"photos": new}).json()["code"], "under_review")

    def test_orders_from_before_copies_were_kept_get_one_before_the_photos_change(self):
        from vitrina_api.models import Order
        listing, order = self.ordered()
        with self.db() as db:
            db.get(Order, order["id"]).listing_photos = None
            db.commit()
        new = [{**p, "url": p["url"].replace("/p", "/q")} for p in PHOTOS]
        self.assertEqual(self.patch(listing["id"], {"photos": new}).status_code, 200)
        seen = self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["listing_photos"]
        self.assertEqual([p["original_url"] for p in seen], [p["url"] for p in PHOTOS])

    def test_others_files_cannot_be_added(self):
        lid = self.publish()["id"]
        self.app.state.settings.allow_external_media = False
        r = self.patch(lid, {"add_photos": [{"url": "http://test/media/999/" + "a" * 32 + ".jpg", "angle": "top"}]})
        self.assertEqual(r.json()["code"], "foreign_media")


def mp4(tag="Almaty 43.25 76.95") -> bytes:
    """A one-second clip carrying a location tag, as phones write one."""
    import subprocess
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "v.mp4")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
                        "-t", "1", "-pix_fmt", "yuv420p", "-metadata", f"title={tag}",
                        "-metadata", "comment=Phone XYZ", out], check=True)
        with open(out, "rb") as f:
            return f.read()


def amplified(clip: bytes) -> bytes:
    """The clip with a sample table that points every frame at the whole media data, as an attacker would write it:
    a plain stream copy would repeat those bytes once per frame."""
    import struct
    d = bytearray(clip)

    def find(start, end, path):
        i = start
        while i < end:
            size, tag = struct.unpack(">I4s", d[i:i + 8])
            if tag == path[0]:
                return [i] + (find(i + 8, i + size, path[1:]) if len(path) > 1 else [])
            i += size
        raise KeyError(path)

    mdat = find(0, len(d), [b"mdat"])[0]
    per = struct.unpack(">I", d[mdat:mdat + 4])[0] - 8
    chain = find(0, len(d), [b"moov", b"trak", b"mdia", b"minf", b"stbl"])
    stbl = chain[-1]
    stsz = find(stbl + 8, stbl + struct.unpack(">I", d[stbl:stbl + 4])[0], [b"stsz"])[0]
    n = struct.unpack(">I", d[stsz + 16:stsz + 20])[0]
    for k in range(n):
        struct.pack_into(">I", d, stsz + 20 + 4 * k, per)

    def replace(tag, new):
        nonlocal d
        stbl = chain[-1]
        i = find(stbl + 8, stbl + struct.unpack(">I", d[stbl:stbl + 4])[0], [tag])[0]
        delta = len(new) - struct.unpack(">I", d[i:i + 4])[0]
        d = d[:i] + new + d[i + struct.unpack(">I", d[i:i + 4])[0]:]
        for box in chain:
            struct.pack_into(">I", d, box, struct.unpack(">I", d[box:box + 4])[0] + delta)

    replace(b"stsc", struct.pack(">I4sIIIII", 28, b"stsc", 0, 1, 1, 1, 1))
    replace(b"stco", struct.pack(">I4sII", 16 + 4 * n, b"stco", 0, n) + struct.pack(f">{n}I", *([mdat + 8] * n)))
    return bytes(d)


class DisputeEvidenceTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def add(self, order, token, data=None, name="p.jpg", ctype="image/jpeg", note=None, key=None):
        form = {k: v for k, v in {"note": note, "key": key}.items() if v is not None}
        return self.c.post(f"/api/v1/orders/{order['id']}/evidence", headers=self.h(token),
                           files={"file": (name, data or jpeg(gps=True), ctype)}, data=form or None)

    def evidence_count(self):
        from vitrina_api.models import OrderEvidence
        with self.db() as db:
            return db.query(OrderEvidence).count()

    def disputed(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Басқа модель келді"})
        return order

    def test_the_order_keeps_what_the_listing_said(self):
        listing, order = self.ordered()
        r = self.c.patch(f"/api/v1/listings/{listing['id']}", headers=self.h(self.seller),
                         json={"description": "Жаңа сипаттама"})
        self.assertEqual(r.status_code, 200, r.text)
        details = self.get(f"/orders/{order['id']}", self.buyer).json()["listing_details"]
        self.assertEqual(details["title"], listing["title"])
        self.assertEqual(details["condition"], listing["condition"])
        self.assertNotEqual(details["description"], "Жаңа сипаттама")
        staff = self.make_staff()
        seen = self.get(f"/admin/orders/{order['id']}/evidence", staff).json()
        self.assertEqual(seen["listing_details"], details)

    def test_both_sides_add_evidence_only_while_a_return_or_dispute_is_open(self):
        _, order = self.delivered()
        # The buyer may photograph the pair during the inspection days; the seller has nothing to answer yet.
        self.assertEqual(self.add(order, self.seller).json()["code"], "invalid_status")
        self.post(f"/orders/{order['id']}/return", self.buyer, {"reason": "Табанында жарық бар"})
        r = self.add(order, self.buyer, note="  Табаны  ")
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual((r.json()["from"], r.json()["kind"], r.json()["note"]), ("buyer", "photo", "Табаны"))
        with Image.open(io.BytesIO(self.fetch(r.json()["url"]).content)) as img:
            self.assertNotIn(0x8825, img.getexif())  # no place left in the photo
        from vitrina_api.models import OrderEvidence
        with self.db() as db:  # kept apart from the public photos
            self.assertTrue(db.scalars(select(OrderEvidence.url)).first().startswith("private:/"))
        self.assertEqual(self.add(order, self.seller).status_code, 201)
        self.post(f"/orders/{order['id']}/dispute", self.seller, {"reason": "Аяқ киім киілген"})
        self.assertEqual(self.add(order, self.seller).status_code, 201)
        got = self.get(f"/orders/{order['id']}", self.buyer).json()["evidence"]
        self.assertEqual([e["from"] for e in got], ["buyer", "seller", "seller"])
        self.assertIsNotNone(self.get(f"/orders/{order['id']}", self.buyer).json()["evidence_until"])
        self.assertEqual(self.get(f"/orders/{order['id']}", self.seller).json()["evidence"], got)
        staff = self.make_staff()
        self.assertEqual(self.get(f"/admin/orders/{order['id']}/evidence", staff).json()["evidence"], got)
        # Support cannot add to a side's evidence, and strangers do not learn the order exists.
        self.assertEqual(self.add(order, staff).status_code, 404)
        self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 0, "reason": "Киілген"})
        self.assertEqual(self.add(order, self.buyer).json()["code"], "invalid_status")

    def test_nothing_can_be_added_before_the_pair_arrives(self):
        _, order = self.ordered()
        self.assertEqual(self.add(order, self.buyer).json()["code"], "invalid_status")

    def test_evidence_is_capped_and_must_be_a_picture_or_a_video(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Басқа модель келді"})
        self.assertEqual(self.add(order, self.buyer, b"hello", "x.txt", "text/plain").status_code, 415)
        for _ in range(10):
            self.assertEqual(self.add(order, self.buyer).status_code, 201)
        self.assertEqual(self.add(order, self.buyer).json()["code"], "too_much_evidence")
        self.assertEqual(self.add(order, self.seller).status_code, 201)  # the cap is per side

    @unittest.skipUnless(promo.available(), "ffmpeg not installed")
    def test_a_video_is_kept_without_its_metadata(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Басқа модель келді"})
        clip = mp4()
        self.assertTrue(b"Almaty" in clip and b"Phone XYZ" in clip)
        r = self.add(order, self.buyer, clip, "v.mp4", "video/mp4")
        self.assertEqual(r.status_code, 201, r.text)
        self.assertEqual(r.json()["kind"], "video")
        self.assertIn(".mp4?", r.json()["url"])
        kept = self.fetch(r.json()["url"]).content
        self.assertFalse(b"Almaty" in kept or b"Phone XYZ" in kept)
        broken = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 100
        self.assertEqual(self.add(order, self.buyer, broken, "v.mp4", "video/mp4").status_code, 415)

    @unittest.skipUnless(promo.available(), "ffmpeg not installed")
    def test_a_video_that_would_balloon_when_copied_is_refused(self):
        order = self.disputed()
        r = self.add(order, self.buyer, amplified(mp4()), "v.mp4", "video/mp4")
        self.assertEqual((r.status_code, r.json()["code"]), (415, "unsupported_video"))
        self.assertEqual(self.evidence_count(), 0)

    def test_a_heic_still_is_treated_as_a_photo_not_a_video(self):
        order = self.disputed()
        heic = b"\x00\x00\x00\x18ftypheic" + b"\x00" * 200
        r = self.add(order, self.buyer, heic, "p.heic", "image/heic")
        self.assertEqual((r.status_code, r.json()["code"]), (415, "unsupported_media"))

    def test_without_ffmpeg_a_video_is_turned_away_as_a_server_problem(self):
        from unittest import mock
        order = self.disputed()
        with mock.patch("vitrina_api.storage.shutil.which", return_value=None):
            r = self.add(order, self.buyer, b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 100, "v.mp4", "video/mp4")
        self.assertEqual((r.status_code, r.json()["code"]), (503, "video_unavailable"))

    def test_a_retry_with_the_same_key_adds_no_second_copy(self):
        order = self.disputed()
        first = self.add(order, self.buyer, key="k-0123456789")
        again = self.add(order, self.buyer, key="k-0123456789")
        self.assertEqual((first.status_code, again.status_code), (201, 201))
        self.assertEqual(first.json()["id"], again.json()["id"])
        self.assertEqual(self.evidence_count(), 1)
        self.assertEqual(self.add(order, self.seller, key="k-0123456789").json()["id"] != first.json()["id"], True)

    def test_tries_are_limited_even_when_refused(self):
        from vitrina_api.search_routes import SlidingWindowLimiter
        order = self.disputed()
        self.app.state.evidence_limiter = SlidingWindowLimiter(2, 3600)
        for _ in range(2):
            self.assertEqual(self.add(order, self.buyer, b"hello", "x.txt", "text/plain").status_code, 415)
        self.assertEqual(self.add(order, self.buyer).json()["code"], "rate_limited")

    def test_an_order_closed_while_the_file_was_cleaned_keeps_no_evidence(self):
        from unittest import mock
        from vitrina_api import storage as storage_module
        order = self.disputed()
        staff = self.make_staff()
        real = storage_module.normalize_image

        def resolve_meanwhile(data):
            self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 0, "reason": "Шешілді", "early": True})
            return real(data)

        with mock.patch("vitrina_api.order_routes.normalize_image", side_effect=resolve_meanwhile):
            r = self.add(order, self.buyer)
        self.assertEqual((r.status_code, r.json()["code"]), (409, "invalid_status"))
        self.assertEqual(self.evidence_count(), 0)

    def test_an_order_from_a_description_the_buyer_did_not_see_is_refused(self):
        listing = self.publish()
        r = self.c.patch(f"/api/v1/listings/{listing['id']}", headers=self.h(self.seller),
                         json={"description": "Жаңа сипаттама"})
        self.assertEqual(r.status_code, 200, r.text)
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"],
                "photos_version": listing["photos_version"]}
        r = self.post("/orders", self.buyer, body, **{"Idempotency-Key": "dv1"})
        self.assertEqual((r.status_code, r.json()["code"]), (409, "photos_changed"))

    def test_support_waits_for_both_sides_or_decides_early_on_purpose(self):
        order = self.disputed()
        staff = self.make_staff()
        decide = {"refund_tiyn": 0, "reason": "Аяқ киім сай"}
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff, decide)
        self.assertEqual((r.status_code, r.json()["code"]), (409, "evidence_window_open"))
        self.assertEqual(self.post(f"/admin/orders/{order['id']}/request-evidence", staff,
                                   {"side": "seller", "note": "Жіберер алдындағы фото керек"}).status_code, 200)
        with self.db() as db:
            from vitrina_api.models import Notification
            texts = [n.text_kk for n in db.query(Notification).filter_by(user_id=order["seller_id"]).all()]
        self.assertTrue(any("Жіберер алдындағы фото керек" in t for t in texts))
        seen = self.get(f"/admin/orders/{order['id']}/evidence", staff).json()
        self.assertEqual(seen["evidence_requests"][0]["reason"], "seller: Жіберер алдындағы фото керек")
        self.add(order, self.buyer)
        self.add(order, self.seller)
        row = next(o for o in self.get("/admin/orders?status=DISPUTED", staff).json()["items"] if o["id"] == order["id"])
        self.assertEqual(row["evidence_count"], 2)
        self.assertEqual(self.post(f"/admin/orders/{order['id']}/resolve", staff, decide).json()["status"], "COMPLETED")

    def test_support_may_decide_inside_the_window_when_it_says_so(self):
        order = self.disputed()
        staff = self.make_staff()
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff,
                      {"refund_tiyn": 0, "reason": "Сатып алушы дауды қайтарды", "early": True})
        self.assertEqual(r.json()["status"], "COMPLETED")

    def test_the_order_keeps_the_authenticity_claim_and_paid_proofs_stay(self):
        listing, order = self.ordered()
        self.assertEqual(self.get(f"/orders/{order['id']}", self.buyer).json()["listing_details"]["authenticity"],
                         listing["authenticity"])
        r = self.c.post(f"/api/v1/listings/{listing['id']}/proofs", headers=self.h(self.seller),
                        files={"file": ("p.jpg", jpeg(), "image/jpeg")})
        proof = r.json()["proofs"][0]["id"]
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        r = self.c.delete(f"/api/v1/listings/{listing['id']}/proofs/{proof}", headers=self.h(self.seller))
        self.assertEqual(r.json()["code"], "proof_in_use")

    def test_support_gives_a_reason_for_a_decision(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/dispute", self.buyer, {"reason": "Басқа модель келді"})
        staff = self.make_staff()
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 0, "reason": "  "})
        self.assertEqual(r.json()["code"], "reason_required")
        self.assertEqual(self.get(f"/orders/{order['id']}", self.buyer).json()["status"], "DISPUTED")


class OrphanSweepTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        from vitrina_api import orphans
        self.orphans, self.storage, self.now = orphans, self.app.state.storage, datetime.now(timezone.utc)
        jpeg = io.BytesIO()
        Image.new("RGB", (8, 8)).save(jpeg, "JPEG")
        self.jpeg = jpeg.getvalue()

    def stored(self, days_old):
        url = self.storage.put(self.jpeg, owner_id=1)
        when = (self.now - timedelta(days=days_old)).timestamp()
        os.utime(os.path.join(self.cfg.media_dir, self.key(url)), (when, when))
        return url

    def key(self, url):
        return url.split("/media/")[1]

    def point_at(self, *texts):
        with self.db() as db:
            db.query(User).filter_by(phone="+77010000002").one().last_delivery = json.dumps(list(texts))
            db.commit()

    def sweep(self, **kw):
        return self.orphans.sweep(self.app.state.sessions, self.storage, now=self.now, **kw)

    def test_only_old_files_no_row_points_at_are_removed(self):
        listed, ordered, moved, escaped, lost = (self.stored(8) for _ in range(5))
        young, almost = self.stored(0), self.stored(6.9)
        photos = [{**p, "url": listed} if p["angle"] == "front" else p for p in PHOTOS]
        listing = self.publish(photos=photos)
        # Inside a JSON text, under an address saved before the public media URL changed, and percent-encoded.
        self.point_at(ordered, "https://old-cdn.example/" + self.key(moved),
                      "https://cdn.example/" + self.key(escaped).replace("/", "%2F"))
        found = self.sweep()
        self.assertEqual(found.orphans, [self.key(lost)])
        self.assertTrue(self.storage.read(lost))  # a dry run deletes nothing
        done = self.sweep(delete=True, force=True)
        self.assertEqual(done.deleted, [self.key(lost)])
        with self.assertRaises(FileNotFoundError):
            self.storage.read(lost)
        for url in (listed, ordered, moved, escaped, young, almost):
            self.assertEqual(self.storage.read(url), self.jpeg)
        with self.db() as db:  # the listing's photo is still there
            self.assertIn(listed, [m.original_url for m in db.get(Listing, listing["id"]).media])

    def test_a_row_written_while_the_files_are_listed_still_keeps_its_file(self):
        self.point_at(*(self.stored(8) for _ in range(9)))
        late = self.stored(8)
        listing = self.storage.keys

        def keys():
            for item in listing():
                yield item
            self.point_at(late)  # the seller saves while the sweep is listing the files

        self.storage.keys = keys
        self.assertEqual(self.sweep(delete=True).orphans, [])
        self.assertEqual(self.storage.read(late), self.jpeg)

    def test_refuses_when_too_many_files_look_unused_or_the_database_points_at_nothing(self):
        kept = self.stored(8)
        self.point_at(kept)
        lost = [self.stored(8) for _ in range(21)]
        with self.assertRaises(self.orphans.SweepRefused):
            self.sweep(delete=True)  # 21 of 22: more likely the wrong database than real leftovers
        for url in lost:
            self.assertEqual(self.storage.read(url), self.jpeg)
        self.point_at()
        with self.db() as db:
            db.execute(Base.metadata.tables["media"].delete())
            db.commit()
        with self.assertRaises(self.orphans.SweepRefused):
            self.sweep(delete=True, force=True)

    def test_a_small_store_loses_its_few_leftovers_even_when_they_are_most_of_it(self):
        kept = self.stored(8)
        self.point_at(kept)
        lost = [self.stored(8) for _ in range(3)]
        self.assertEqual(len(self.sweep(delete=True).deleted), 3)  # 3 of 4, but only 3: no reason to stop
        self.assertEqual(self.storage.read(kept), self.jpeg)
        with self.assertRaises(FileNotFoundError):
            self.storage.read(lost[0])

    def test_the_command_sweeps_private_files_too_and_keeps_the_ones_in_use(self):
        from contextlib import redirect_stdout
        from unittest import mock
        from vitrina_api.models import AuthProof
        private = self.app.state.private
        lid = self.publish()["id"]
        r = self.c.post(f"/api/v1/listings/{lid}/proofs", headers=self.h(self.seller),
                        files={"file": ("receipt.jpg", jpeg(), "image/jpeg")})
        self.assertEqual(r.status_code, 201, r.text)
        stray = private.put(self.jpeg, owner_id=1)
        when = (self.now - timedelta(days=8)).timestamp()
        with self.db() as db:
            proof = db.scalars(select(AuthProof.url)).one()
        for ref in (stray, proof):
            os.utime(os.path.join(self.cfg.private_media_dir, ref.removeprefix("private:/")), (when, when))
        self.point_at(*(self.stored(8) for _ in range(3)))
        with mock.patch("vitrina_api.config.Settings", lambda: self.cfg), redirect_stdout(io.StringIO()):
            self.assertEqual(self.orphans.main(["--delete"]), 0)
        with self.assertRaises(FileNotFoundError):
            private.read(stray)
        proofs = self.c.get(f"/api/v1/listings/{lid}/proofs", headers=self.h(self.seller)).json()["proofs"]
        self.fetch(proofs[0]["url"])  # the receipt in use is still there

    def test_the_command_lists_by_default_and_records_a_delete(self):
        from contextlib import redirect_stdout
        from unittest import mock
        from vitrina_api.models import AuditLog
        self.point_at(*(self.stored(8) for _ in range(9)))
        lost = self.stored(8)
        out = io.StringIO()
        with mock.patch("vitrina_api.config.Settings", lambda: self.cfg), redirect_stdout(out):
            self.assertEqual(self.orphans.main([]), 0)
            self.assertEqual(self.storage.read(lost), self.jpeg)
            self.assertEqual(self.orphans.main(["--delete"]), 0)
        self.assertIn(self.key(lost), out.getvalue())
        self.assertIn("deleted 1, failed 0", out.getvalue())
        with self.assertRaises(FileNotFoundError):
            self.storage.read(lost)
        with self.db() as db:  # one record per store: the photos and the private files
            self.assertEqual(db.query(AuditLog).filter_by(action="orphans.delete").count(), 2)


if __name__ == "__main__":
    unittest.main()
