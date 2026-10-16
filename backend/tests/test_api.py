"""End-to-end API tests for scenarios A–E from the Phase 1 doc, plus security cases."""
import json
import os
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from vitrina_api.app import create_app
from vitrina_api.config import Settings
from vitrina_api.models import User
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
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = Settings(database_url=f"sqlite:///{os.path.join(self.tmp.name, 't.db')}", debug_otp=True)
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
