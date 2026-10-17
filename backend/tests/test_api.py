"""End-to-end API tests for scenarios A–E from the Phase 1 doc, plus security cases."""
import io
import json
import os
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import create_engine

from vitrina_api.app import create_app
from vitrina_api.config import Settings
from vitrina_api.models import Base, User
from vitrina_api.services import balance, run_auto_complete
from vitrina_core.money import PLATFORM_FEE, buyer_refund, escrow, seller_payable
from vitrina_core.webhooks import sign

PHOTOS = [{"url": f"https://cdn.example/p{i}.jpg", "angle": a}
          for i, a in enumerate(["front", "outer", "inner", "back", "sole"])]
LISTING = {
    "title": "Күнделікті кроссовка", "category": "sneakers", "brand": "Найк", "model_name": "Runner 01",
    "color": "құм", "condition": "used_excellent", "price_tiyn": 4_500_000, "delivery_price_tiyn": 150_000,
    "sizes": [{"label": "EU 42", "insole_cm": "26,5", "quantity": 1}], "photos": PHOTOS,
}


class ApiTestCase(unittest.TestCase):
    external_media = True

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        url = os.environ.get("VITRINA_TEST_DATABASE_URL")  # e.g. PostgreSQL in CI; each test starts empty
        if url:
            engine = create_engine(url)
            Base.metadata.drop_all(engine)
            engine.dispose()
        self.cfg = Settings(database_url=url or f"sqlite:///{os.path.join(self.tmp.name, 't.db')}", debug_otp=True,
                            media_dir=os.path.join(self.tmp.name, "media"), public_media_url="http://test/media",
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

    def make_staff(self, phone="+77010000009"):
        token = self.login(phone)
        with self.db() as db:
            u = db.query(User).filter_by(phone=phone).one()
            u.role = "support"
            db.commit()
        return token


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

    def test_stock_drives_sold_and_restock(self):
        listing = self.publish()
        lid, size_id = listing["id"], listing["sizes"][0]["id"]
        self.assertEqual(self.patch(lid, {"sizes": [{"id": size_id, "quantity": 0}]}).json()["status"], "sold")
        self.assertEqual(self.patch(lid, {"sizes": [{"id": size_id, "quantity": 2}]}).json()["status"], "paused")
        self.assertEqual(self.patch(lid, {"sizes": [{"id": 9999, "quantity": 2}]}).status_code, 422)

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
        self.assertEqual(other.status_code, 404)  # listing sold out -> no longer published

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
        r = self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 1_000_000, "reason": "Фото ақауды растайды"})
        self.assertEqual(r.json()["status"], "REFUND_PENDING")
        bad = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "rf_0", "type": "refund.succeeded", "order_id": order["id"], "amount_tiyn": 5, "currency": "KZT"})
        self.assertEqual(bad.status_code, 409)
        ok = self.hook("payments/sandbox", self.cfg.payment_webhook_secret, {
            "id": "rf_1", "type": "refund.succeeded", "order_id": order["id"], "amount_tiyn": 1_000_000, "currency": "KZT"})
        self.assertEqual(ok.json()["status"], "REFUNDED")
        with self.db() as db:
            buyer_id = db.query(User).filter_by(phone="+77010000002").one().id
            self.assertEqual(balance(db, buyer_refund(str(buyer_id))), 1_000_000)
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
        self.assertGreater(buyer_note["unread"], 0)
        self.post("/notifications/read-all", self.buyer)
        self.assertEqual(self.get("/notifications", self.buyer).json()["unread"], 0)


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
        self.post(f"/admin/orders/{order['id']}/resolve", staff, {"refund_tiyn": 0, "reason": "Өлшем кестесіне сай"})
        audit = self.c.get("/api/v1/admin/audit", headers=self.h(staff)).json()["items"]
        self.assertEqual(audit[0]["action"], "resolve_dispute")


class WebhookSecurityTests(ApiTestCase):
    def test_scenario_e_duplicate_and_forged_payments(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.assertEqual(self.pay(order, amount=1).status_code, 409)
        self.assertEqual(self.pay(order, event_id="evt_x", amount=None).json()["status"], "PAID")
        self.assertEqual(self.pay(order, event_id="evt_x").json()["result"], "duplicate")
        self.assertEqual(self.pay(order, event_id="evt_y").json()["result"], "duplicate")
        with self.db() as db:
            self.assertEqual(balance(db, escrow(str(order["id"]))), order["total_tiyn"])

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


if __name__ == "__main__":
    unittest.main()
