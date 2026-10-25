"""Alerts on the phone while the app is closed (vitrina_api/push.py): which phone hears what, and when it stops."""
import base64
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from sqlalchemy import select, update

from tests.test_api import LISTING, ApiTestCase
from vitrina_api import push, services
from vitrina_api.deps import now_utc
from vitrina_api.models import AuthToken, Notification, PushDevice, User
from vitrina_api.services import notify, run_purge

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PEM = KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption()).decode()
CREDS = push.Credentials(project_id="vitrina-test", client_email="push@vitrina-test.iam.gserviceaccount.com",
                         private_key=PEM, token_uri="https://oauth2.googleapis.com/token")
PHONE_A = "fcm-token-of-phone-a:" + "a" * 40
PHONE_B = "fcm-token-of-phone-b:" + "b" * 40


def unb64(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class FakeGoogle:
    """Google's token and FCM endpoints. A token's answers can be queued: [503, 200] fails once, then takes it."""

    def __init__(self):
        self.sent: list[dict] = []
        self.grants = 0
        self.answers: dict[str, list[int]] = {}  # 0: the connection drops
        self.revoke_next = False
        self.key_refused = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "oauth2.googleapis.com":
            if self.key_refused:
                return httpx.Response(400, json={"error": "invalid_grant", "error_description": "Invalid JWT Signature."})
            form = parse_qs(request.content.decode())
            assert form["grant_type"] == ["urn:ietf:params:oauth:grant-type:jwt-bearer"]
            head, claims, sig = form["assertion"][0].split(".")
            KEY.public_key().verify(unb64(sig), f"{head}.{claims}".encode(), padding.PKCS1v15(), hashes.SHA256())
            c = json.loads(unb64(claims))
            assert json.loads(unb64(head))["alg"] == "RS256"
            assert c["iss"] == CREDS.client_email and c["aud"] == CREDS.token_uri and c["scope"] == push.SCOPE
            self.grants += 1
            return httpx.Response(200, json={"access_token": f"access-{self.grants}", "expires_in": 3599})
        assert request.url.path == "/v1/projects/vitrina-test/messages:send"
        if self.revoke_next:
            self.revoke_next = False
            return httpx.Response(401, json={"error": {"status": "UNAUTHENTICATED"}})
        assert request.headers["Authorization"] == f"Bearer access-{self.grants}"
        msg = json.loads(request.content)["message"]
        queued = self.answers.get(msg["token"])
        status = queued.pop(0) if queued else 200
        if status == 0:
            raise httpx.ConnectError("no route to host", request=request)
        if status == 404:
            return httpx.Response(404, json={"error": {"status": "NOT_FOUND", "details": [
                {"@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": "UNREGISTERED"}]}})
        if status != 200:
            return httpx.Response(status, json={"error": {"status": "UNAVAILABLE"}})
        self.sent.append(msg)
        return httpx.Response(200, json={"name": "projects/vitrina-test/messages/1"})


class PushTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.google = FakeGoogle()
        self.fcm = push.Fcm(CREDS, httpx.Client(transport=httpx.MockTransport(self.google)))
        self.pauses = []

    def run_push(self, **kw):
        return push.run_once(self.app.state.sessions, self.fcm, pause=self.pauses.append, **kw)

    def phone(self, token, device=PHONE_A, lang="kk"):
        r = self.c.put("/api/v1/me/push", json={"token": device, "lang": lang}, headers=self.h(token))
        self.assertEqual(r.status_code, 204, r.text)

    def chat(self, text="Сәлем, 42 өлшемі бар ма?"):
        """The buyer writes to the seller; the seller is the one to hear of it."""
        listing = self.publish()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        self.run_push()  # whatever publishing told the seller is out of the way
        self.google.sent.clear()
        self.assertEqual(self.post(f"/conversations/{cid}/messages", self.buyer, {"body": text}).status_code, 201)
        return cid

    def test_a_chat_message_reaches_the_sellers_phone_once_in_its_language(self):
        self.phone(self.seller, lang="ru")
        cid = self.chat()
        self.assertEqual(self.run_push()[1], 1)
        [msg] = self.google.sent
        self.assertEqual(msg["token"], PHONE_A)
        self.assertEqual(msg["notification"]["body"], "Новое сообщение: Сәлем, 42 өлшемі бар ма?")
        self.assertEqual(msg["data"]["kind"], "message")
        self.assertEqual(msg["data"]["conversation_id"], str(cid))
        self.assertTrue(all(isinstance(v, str) for v in msg["data"].values()), "FCM data takes strings only")
        self.assertEqual(msg["android"], {"priority": "HIGH",
                                          "notification": {"channel_id": "vitrina_alerts", "tag": f"chat-{cid}"}})
        self.assertEqual(self.run_push(), (0, 0), "a notification is pushed once")
        self.assertEqual(len(self.google.sent), 1)
        self.assertEqual(self.google.grants, 1, "the access token is reused")

    def test_signing_out_stops_the_alerts_even_when_signed_in_elsewhere(self):
        self.phone(self.seller)
        second = self.login("+77010000001")  # the same seller on another phone
        self.phone(second, PHONE_B)
        self.assertEqual(self.c.post("/api/v1/auth/logout", headers=self.h(self.seller)).status_code, 200)
        listing = self.publish_with(second)
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        self.run_push()
        self.google.sent.clear()
        self.post(f"/conversations/{cid}/messages", self.buyer, {"body": "Бар ма?"})
        self.run_push()
        self.assertEqual([m["token"] for m in self.google.sent], [PHONE_B])
        self.assertEqual(self.c.post("/api/v1/auth/logout?everywhere=true", headers=self.h(second)).status_code, 200)
        with self.db() as db:
            self.assertEqual(db.scalars(select(PushDevice)).all(), [])

    def publish_with(self, token):
        listing = self.post("/listings", token, LISTING)
        return self.post(f"/listings/{listing.json()['id']}/publish", token).json()

    def test_a_phone_belongs_to_whoever_signed_in_on_it_last(self):
        self.phone(self.buyer)
        self.phone(self.seller)  # the buyer signed out without the server hearing, the seller signed in
        with self.db() as db:
            [device] = db.scalars(select(PushDevice)).all()
            self.assertEqual(device.user_id, db.scalar(select(User.id).where(User.phone == "+77010000001")))
        self.phone(self.seller, PHONE_B)  # Firebase gave the phone a new token: the old one goes
        with self.db() as db:
            self.assertEqual([d.token for d in db.scalars(select(PushDevice))], [PHONE_B])
        self.assertEqual(self.c.delete("/api/v1/me/push", headers=self.h(self.seller)).status_code, 204)
        with self.db() as db:
            self.assertEqual(db.scalars(select(PushDevice)).all(), [])

    def test_a_sign_in_that_ended_or_a_blocked_account_hears_nothing(self):
        self.phone(self.seller)
        with self.db() as db:
            db.execute(update(AuthToken).values(expires_at=now_utc() - timedelta(minutes=1)))
            seller_id = db.scalar(select(User.id).where(User.phone == "+77010000001"))
            notify(db, seller_id, "order_status", "Тапсырыс", "Заказ", "Order", order_id=1)
            db.commit()
        self.assertEqual(self.run_push(), (1, 0))
        with self.db() as db:
            self.assertEqual(run_purge(db, now=now_utc()), ["push_devices:1"])
        self.seller = self.login("+77010000001")
        self.phone(self.seller)
        with self.db() as db:
            db.get(User, seller_id).is_blocked = True
            notify(db, seller_id, "order_status", "Тапсырыс", "Заказ", "Order", order_id=1)
            db.commit()
        self.assertEqual(self.run_push(), (1, 0))
        self.assertEqual(self.google.sent, [])

    def test_a_deleted_account_leaves_no_phone(self):
        self.phone(self.buyer)
        self.assertEqual(self.c.delete("/api/v1/me", headers=self.h(self.buyer)).status_code, 200)
        with self.db() as db:
            self.assertEqual(db.scalars(select(PushDevice)).all(), [])

    def test_a_phone_firebase_no_longer_knows_is_forgotten(self):
        self.phone(self.seller)
        self.google.answers[PHONE_A] = [404]
        self.chat()
        self.assertEqual(self.run_push()[1], 0)
        with self.db() as db:
            self.assertEqual(db.scalars(select(PushDevice)).all(), [])

    def test_a_send_google_could_not_take_is_tried_again_then_let_go(self):
        self.phone(self.seller)
        self.google.answers[PHONE_A] = [503, 429]
        self.chat()
        self.assertEqual(self.run_push()[1], 1)
        self.assertEqual(self.pauses, [2, 8])
        self.google.answers[PHONE_A] = [503, 503, 503]
        self.pauses.clear()
        self.post(f"/conversations/{self.chat_id()}/messages", self.buyer, {"body": "Тағы"})
        self.assertEqual(self.run_push(), (1, 0))
        self.assertEqual(self.pauses, [2, 8])
        with self.db() as db:
            self.assertEqual(len(db.scalars(select(PushDevice)).all()), 1, "Google being down is not the phone's fault")
        self.assertEqual(self.run_push(), (1, 1), "put back, it goes on the next pass")
        self.assertEqual(self.google.sent[-1]["notification"]["body"], "Жаңа хабарлама: Тағы")

    def test_google_out_of_reach_stops_the_batch_and_keeps_the_alerts(self):
        self.phone(self.seller)
        self.phone(self.login("+77010000001"), PHONE_B)  # the seller's second phone
        self.google.answers[PHONE_A] = [0]
        self.google.answers[PHONE_B] = [200]
        self.chat()
        self.assertEqual(self.run_push(), (1, 0))
        self.assertEqual(self.pauses, [], "no waiting inside the pass: the next pass tries again")
        self.assertEqual(self.google.answers[PHONE_B], [200], "the rest of the batch was not tried against a dead line")
        self.assertEqual(self.run_push(), (1, 2))

    def test_a_refused_key_takes_nothing(self):
        self.phone(self.seller)
        self.chat()
        self.google.key_refused = True
        self.fcm._access = None  # the key was replaced, or revoked, since the last token
        with self.assertRaises(httpx.HTTPStatusError):
            self.run_push()
        with self.db() as db:
            self.assertIsNone(db.scalar(select(Notification.pushed_at).where(Notification.kind == "message")))
        self.google.key_refused = False
        self.assertEqual(self.run_push(), (1, 1))

    def test_quiet_news_waits_for_the_morning_and_urgent_goes_first(self):
        self.phone(self.buyer)
        with self.db() as db:
            buyer_id = db.scalar(select(User.id).where(User.phone == "+77010000002"))
            notify(db, buyer_id, "price_drop", "Арзандады", "Подешевело", "Cheaper", listing_id=5)
            notify(db, buyer_id, "order_status", "Жіберілді", "Отправлен", "Shipped", order_id=7)
            db.commit()
            night = datetime(2026, 10, 25, 18, 30, tzinfo=timezone.utc)  # 23:30 in Almaty
            db.execute(update(Notification).values(created_at=night - timedelta(minutes=10)))
            db.commit()
        self.assertEqual(self.run_push(now=night), (1, 1))
        self.assertEqual(self.google.sent[0]["data"]["kind"], "order_status")
        self.assertEqual(self.google.sent[0]["android"]["notification"]["channel_id"], "vitrina_alerts")
        self.assertEqual(self.run_push(now=night + timedelta(hours=4)), (0, 0), "still night")
        morning = night + timedelta(hours=9)  # 08:30 in Almaty
        self.assertEqual(self.run_push(now=morning), (1, 1))
        news = self.google.sent[1]
        self.assertEqual(news["data"]["kind"], "price_drop")
        self.assertEqual(news["android"], {"priority": "NORMAL",
                                           "notification": {"channel_id": "vitrina_news", "tag": "price_drop"}})

    def test_with_push_off_old_notifications_are_marked(self):
        with self.db() as db:
            seller_id = db.scalar(select(User.id).where(User.phone == "+77010000001"))
            notify(db, seller_id, "order_status", "Тапсырыс", "Заказ", "Order", order_id=1)
            db.commit()
        push.let_go_old(self.app.state.sessions, now_utc())
        with self.db() as db:
            self.assertIsNone(db.scalar(select(Notification.pushed_at).where(Notification.order_id == 1)))
        push.let_go_old(self.app.state.sessions, now_utc() + push.NEWS_MAX_AGE + timedelta(minutes=1))
        with self.db() as db:
            self.assertIsNotNone(db.scalar(select(Notification.pushed_at).where(Notification.order_id == 1)))

    def test_a_phone_that_keeps_opening_the_app_keeps_its_sign_in(self):
        staff = self.make_staff()
        with self.db() as db:
            db.execute(update(AuthToken).values(expires_at=now_utc() + timedelta(days=3)))
            db.commit()
        self.phone(self.seller)
        self.phone(staff, PHONE_B)
        with self.db() as db:
            left = {u: services.aware(e) - now_utc() for u, e in db.execute(
                select(User.role, AuthToken.expires_at).join(User, User.id == AuthToken.user_id)
                .join(PushDevice, PushDevice.auth_token_id == AuthToken.id))}
        self.assertGreater(left["user"], timedelta(days=29))
        self.assertLess(left["support"], timedelta(days=3), "staff sign-ins stay short")

    def chat_id(self):
        with self.db() as db:
            return db.scalar(select(Notification.conversation_id).where(Notification.kind == "message"))

    def test_an_access_token_revoked_early_is_replaced_once(self):
        self.phone(self.seller)
        self.chat()
        self.fcm.access_token()
        self.google.revoke_next = True
        self.assertEqual(self.run_push()[1], 1)
        self.assertEqual(self.google.grants, 2)

    def test_news_from_before_an_outage_is_not_pushed_late(self):
        self.phone(self.seller)
        self.chat()
        self.assertEqual(self.run_push(now=now_utc() + push.URGENT_MAX_AGE + timedelta(minutes=1)), (1, 0))
        with self.db() as db:
            self.assertIsNotNone(db.scalar(select(Notification.pushed_at).where(Notification.kind == "message")))

    def test_the_phone_token_is_checked(self):
        for body in ({"token": "short"}, {"token": "x" * 401}, {"token": "a b" * 20}, {"token": PHONE_A, "lang": "de"}):
            self.assertEqual(self.c.put("/api/v1/me/push", json=body, headers=self.h(self.seller)).status_code, 422)
        self.assertEqual(self.c.put("/api/v1/me/push", json={"token": PHONE_A}).status_code, 401)


class CredentialsTests(unittest.TestCase):
    def test_push_is_off_without_a_key_and_refuses_a_wrong_one(self):
        self.assertIsNone(push.load_credentials(""))
        self.assertIsNone(push.load_credentials("/nonexistent/firebase.json"))
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "firebase.json")
            good = {"type": "service_account", "project_id": "p", "client_email": "e", "private_key": PEM,
                    "token_uri": "https://oauth2.googleapis.com/token"}
            for bad in ({**good, "type": "authorized_user"}, {**good, "token_uri": "http://example.kz/token"}):
                with open(path, "w") as f:
                    json.dump(bad, f)
                with self.assertRaises(ValueError):
                    push.load_credentials(path)
            with open(path, "w") as f:
                json.dump(good, f)
            self.assertEqual(push.load_credentials(path).project_id, "p")


if __name__ == "__main__":
    unittest.main()
