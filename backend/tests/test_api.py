"""End-to-end API tests for scenarios A–E from the Phase 1 doc, plus security cases."""
import io
import json
import os
import tempfile
import time
import unittest
from datetime import date, datetime, timedelta, timezone

from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import create_engine

from vitrina_api import promo
from vitrina_api.app import create_app
from vitrina_api.config import Settings
from vitrina_api.models import Base, Conversation, Message, Offer, SavedSearch, User
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
        self.assertNotIn("<b>", page.split("<body>")[1])  # seller text is escaped
        self.assertNotIn("+7701", page)  # never the seller's phone
        self.assertIn("Открыть в приложении", self.c.get(f"/l/{listing['id']}", headers={"Accept-Language": "ru-RU"}).text)
        self.post(f"/listings/{listing['id']}/pause", self.seller)
        self.assertEqual(self.c.get(f"/l/{listing['id']}").status_code, 404)
        self.assertEqual(self.c.get("/l/99999").status_code, 404)


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
        mine = self.c.get("/api/v1/me/listings", headers=self.h(self.seller)).json()["items"][-1]
        r = self.c.patch(f"/api/v1/listings/{mine['id']}", json={"price_tiyn": 4_000_000}, headers=self.h(self.seller))
        self.assertEqual(r.json()["status"], "published")


class OfferTests(ApiTestCase):
    def get(self, path, token):
        return self.c.get(f"/api/v1{path}", headers=self.h(token))

    def offer(self, listing, amount, token=None):
        return self.post(f"/listings/{listing['id']}/offers", token or self.buyer,
                         {"size_id": listing["sizes"][0]["id"], "amount_tiyn": amount})

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

    def test_raising_the_price_ends_the_sale(self):
        listing = self.publish()
        self.patch(listing["id"], 3_000_000)
        self.assertIsNone(self.patch(listing["id"], 4_600_000)["was_price_tiyn"])


class AwayTests(ApiTestCase):
    def put(self, path, token, body):
        return self.c.put(f"/api/v1{path}", json=body, headers=self.h(token))

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
