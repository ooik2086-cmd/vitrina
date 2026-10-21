"""The same request arriving many times at once: a double tap, a phone retrying on a weak line, a webhook delivered
twice. Whatever the order the server takes them in, money moves once, stock never goes below zero and nothing fails.

Runs on PostgreSQL only (VITRINA_TEST_DATABASE_URL): SQLite takes one writer at a time, so nothing races there."""
import os
import threading
import unittest

from sqlalchemy import func, select, text

from tests.test_api import ADDRESS, LISTING, ApiTestCase, jpeg, with_check_digit
from vitrina_api.models import (AuditLog, Conversation, LedgerTx, Listing, ListingSize, Message, Offer, Order,
                                OrderEvent, Payout, Review)

N = 8


@unittest.skipUnless(os.environ.get("VITRINA_TEST_DATABASE_URL"), "races need PostgreSQL")
class RaceTests(ApiTestCase):
    def race(self, *calls):
        """Runs every call at the same moment, each on its own thread; returns the responses in the calls' order."""
        barrier, out = threading.Barrier(len(calls), timeout=30), [None] * len(calls)

        def run(i):
            barrier.wait()
            try:
                out[i] = calls[i]()
            except Exception as exc:  # noqa: BLE001  the server's own error, raised through the test client
                out[i] = exc
        threads = [threading.Thread(target=run, args=(i,)) for i in range(len(calls))]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=60)
            self.assertFalse(t.is_alive(), "a request is still waiting: two locks taken in opposite orders?")
        for r in out:
            self.assertNotIsInstance(r, Exception, repr(r)[:300])
            self.assertLess(r.status_code, 500, r.text)
        return out

    def same(self, call, n=N):
        return self.race(*[call] * n)

    def count(self, model, *where):
        with self.db() as db:
            return db.scalar(select(func.count()).select_from(model).where(*where))

    def kinds(self, order):
        with self.db() as db:
            return db.scalars(select(LedgerTx.kind).where(LedgerTx.order_id == order["id"]).order_by(LedgerTx.id)).all()

    def codes(self, responses):
        return sorted(r.status_code for r in responses)

    def test_a_connection_never_waits_for_ever(self):
        # A stuck query or lock wait is stopped, so a few of them cannot take every connection the server has.
        with self.db() as db:
            self.assertEqual([db.scalar(text(f"show {name}")) for name in
                              ("statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout")],
                             ["30s", "10s", "5min"])

    # Stock and orders

    def test_the_last_pair_goes_to_one_buyer(self):
        listing = self.publish()  # one pair
        buyers = [self.login(f"+7701000010{i}") for i in range(N)]
        size = listing["sizes"][0]["id"]
        rs = self.race(*[lambda t=t: self.post("/orders", t, {"listing_id": listing["id"], "size_id": size},
                                               **{"Idempotency-Key": f"k-{t[-6:]}"}) for t in buyers])
        self.assertEqual([r.status_code for r in rs].count(201), 1, self.codes(rs))
        self.assertEqual({r.json()["code"] for r in rs if r.status_code != 201}, {"out_of_stock"})
        self.assertEqual(self.count(Order), 1)
        with self.db() as db:
            self.assertEqual(db.get(ListingSize, size).quantity, 0)

    def test_the_last_pairs_of_two_sizes_bought_at_once_leave_the_listing_sold(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 1},
                                      {"label": "EU 43", "insole_cm": "27,0", "quantity": 1}])
        a, b = self.login("+77010000301"), self.login("+77010000302")
        rs = self.race(*[lambda t=t, s=s: self.post("/orders", t, {"listing_id": listing["id"], "size_id": s["id"]},
                                                     **{"Idempotency-Key": "two"})
                         for t, s in zip((a, b), listing["sizes"])])
        self.assertEqual(self.codes(rs), [201, 201])
        with self.db() as db:
            self.assertEqual(db.get(Listing, listing["id"]).status, "sold")

    def test_a_cancel_while_another_size_sells_out_leaves_the_listing_on_sale(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 1},
                                      {"label": "EU 43", "insole_cm": "27,0", "quantity": 1}])
        x, y = (s["id"] for s in listing["sizes"])
        first = self.post("/orders", self.buyer, {"listing_id": listing["id"], "size_id": y}, **{"Idempotency-Key": "y"})
        other = self.login("+77010000303")
        self.race(lambda: self.post(f"/orders/{first.json()['id']}/cancel", self.buyer),
                  lambda: self.post("/orders", other, {"listing_id": listing["id"], "size_id": x},
                                    **{"Idempotency-Key": "x"}))
        with self.db() as db:
            self.assertEqual(db.get(Listing, listing["id"]).status, "published")  # EU 43 is back on sale

    def test_the_same_key_for_the_last_pair_answers_every_tap_with_its_order(self):
        listing = self.publish()  # one pair: a lost answer must not turn into "sold out" for its own buyer
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]}
        rs = self.same(lambda: self.post("/orders", self.buyer, body, **{"Idempotency-Key": "last"}))
        self.assertEqual(self.codes(rs), [201] * N, [r.text[:120] for r in rs])
        self.assertEqual(len({r.json()["id"] for r in rs}), 1)

    def test_the_same_new_listing_sent_many_times_at_once_is_made_once(self):
        rs = self.same(lambda: self.post("/listings", self.seller, LISTING, **{"Idempotency-Key": "weak-line-1"}))
        self.assertEqual(self.codes(rs), [201] * N, [r.text[:120] for r in rs])
        self.assertEqual(len({r.json()["id"] for r in rs}), 1)
        self.assertEqual(self.count(Listing, Listing.seller_id == rs[0].json()["seller"]["id"]), 1)

    def test_the_same_message_sent_many_times_at_once_is_posted_once(self):
        listing = self.publish()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        rs = self.same(lambda: self.post(f"/conversations/{cid}/messages", self.buyer, {"body": "Бар ма?"},
                                         **{"Idempotency-Key": "weak-line-msg"}))
        self.assertEqual(self.codes(rs), [201] * N, [r.text[:120] for r in rs])
        self.assertEqual(len({r.json()["id"] for r in rs}), 1)
        self.assertEqual(self.count(Message, Message.conversation_id == cid), 1)

    def test_the_same_chat_photo_sent_many_times_at_once_is_posted_once(self):
        listing = self.publish()
        cid = self.post("/conversations", self.buyer, {"listing_id": listing["id"]}).json()["id"]
        photo = jpeg()
        rs = self.same(lambda: self.c.post(f"/api/v1/conversations/{cid}/photos", data={"caption": "Табаны"},
                                           files={"file": ("p.jpg", photo, "image/jpeg")},
                                           headers={**self.h(self.buyer), "Idempotency-Key": "weak-line-photo"}))
        self.assertEqual(self.codes(rs), [201] * N, [r.text[:120] for r in rs])
        self.assertEqual(len({r.json()["id"] for r in rs}), 1)
        self.assertEqual(self.count(Message, Message.conversation_id == cid), 1)

    def test_the_same_pair_marked_sold_many_times_at_once_is_taken_once(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        size = listing["sizes"][0]["id"]
        rs = self.same(lambda: self.post(f"/listings/{listing['id']}/sizes/{size}/sold", self.seller,
                                         **{"Idempotency-Key": "sold-in-chat"}))
        self.assertEqual(self.codes(rs), [200] * N, [r.text[:120] for r in rs])
        with self.db() as db:
            self.assertEqual(db.get(ListingSize, size).quantity, 4)

    def test_the_same_undo_sent_many_times_at_once_puts_back_one_pair(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        size = listing["sizes"][0]["id"]
        self.post(f"/listings/{listing['id']}/sizes/{size}/sold", self.seller, **{"Idempotency-Key": "sold-by-mistake"})
        rs = self.same(lambda: self.post(f"/listings/{listing['id']}/sizes/{size}/sold/undo", self.seller,
                                         **{"Idempotency-Key": "sold-by-mistake"}))
        self.assertEqual(self.codes(rs), [200] * N, [r.text[:120] for r in rs])
        with self.db() as db:
            self.assertEqual(db.get(ListingSize, size).quantity, 5)
            self.assertEqual(db.scalar(select(func.count(AuditLog.id)).where(AuditLog.action == "undo_pair_sold")), 1)

    def test_marks_and_orders_at_once_never_take_more_pairs_than_there_are(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 3}])
        size = listing["sizes"][0]["id"]
        buyers = [self.login(f"+7701000050{i}") for i in range(N // 2)]
        marks = [lambda i=i: self.post(f"/listings/{listing['id']}/sizes/{size}/sold", self.seller,
                                       **{"Idempotency-Key": f"sold-in-chat-{i}"}) for i in range(N // 2)]
        orders = [lambda t=t: self.post("/orders", t, {"listing_id": listing["id"], "size_id": size},
                                        **{"Idempotency-Key": "order-at-once"}) for t in buyers]
        rs = self.race(*[c for pair in zip(marks, orders) for c in pair])
        self.assertEqual(sum(r.status_code in (200, 201) for r in rs), 3, [r.text[:120] for r in rs])
        self.assertTrue(all(r.status_code in (200, 201, 409) for r in rs), self.codes(rs))
        with self.db() as db:
            self.assertEqual(db.get(ListingSize, size).quantity, 0)

    def test_the_same_key_under_an_agreed_price_answers_every_tap_with_its_order(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        size = listing["sizes"][0]["id"]
        offer = self.post(f"/listings/{listing['id']}/offers", self.buyer, {"size_id": size, "amount_tiyn": 4_000_000})
        self.post(f"/offers/{offer.json()['id']}/accept", self.seller)
        body = {"listing_id": listing["id"], "size_id": size, "offer_id": offer.json()["id"]}
        rs = self.same(lambda: self.post("/orders", self.buyer, body, **{"Idempotency-Key": "agreed"}))
        self.assertEqual(self.codes(rs), [201] * N, [r.text[:120] for r in rs])
        self.assertEqual(len({r.json()["id"] for r in rs}), 1)

    def test_the_seller_saving_stock_while_buyers_order_waits_its_turn(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        size = listing["sizes"][0]["id"]
        buyers = [self.login(f"+7701000040{i}") for i in range(N // 2)]
        edits = [lambda i=i: self.c.patch(f"/api/v1/listings/{listing['id']}", headers=self.h(self.seller),
                                          json={"price_tiyn": 4_500_000 + i * 10_000,
                                                "sizes": [{"id": size, "quantity": 5}]}) for i in range(N // 2)]
        orders = [lambda t=t: self.post("/orders", t, {"listing_id": listing["id"], "size_id": size},
                                        **{"Idempotency-Key": "e"}) for t in buyers]
        rs = self.race(*[c for pair in zip(edits, orders) for c in pair])
        self.assertTrue(all(r.status_code in (200, 201) for r in rs), self.codes(rs))

    def test_one_order_however_often_the_same_key_arrives(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        body = {"listing_id": listing["id"], "size_id": listing["sizes"][0]["id"]}
        rs = self.same(lambda: self.post("/orders", self.buyer, body, **{"Idempotency-Key": "same"}))
        self.assertEqual(len({r.json()["id"] for r in rs if r.status_code == 201}), 1, [r.text for r in rs])
        self.assertEqual(self.count(Order), 1)

    # Money

    def test_a_payment_delivered_many_times_is_counted_once(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.same(lambda: self.pay(order))
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["status"],
                         "PAID")
        self.assertEqual(self.kinds(order), ["payment_captured"])

    def test_confirming_receipt_many_times_pays_the_seller_once(self):
        _, order = self.delivered()
        before = self.kinds(order)
        self.same(lambda: self.post(f"/orders/{order['id']}/confirm", self.buyer))
        kinds = self.kinds(order)
        self.assertGreater(len(kinds), len(before))
        self.assertEqual(len(kinds), len(set(kinds)), kinds)

    def test_support_pays_or_returns_a_payout_once(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        self.c.put("/api/v1/me/payout-account", headers=self.h(self.seller), json={
            "holder_name": "ЖК Qadam Store", "iban": "kz86 125K ZT50 0410 0100",
            "tax_id": with_check_digit("90010130012")})
        payout = self.post("/me/payouts", self.seller).json()
        staff = self.make_staff()
        rs = self.race(*[lambda: self.post(f"/admin/payouts/{payout['id']}/paid", staff, {"bank_ref": "ПП-1"})] * 4,
                       *[lambda: self.post(f"/admin/payouts/{payout['id']}/reject", staff, {"reason": "x"})] * 4)
        self.assertEqual([r.status_code for r in rs].count(200), 1, self.codes(rs))
        with self.db() as db:
            self.assertEqual(db.scalars(select(LedgerTx.kind).where(LedgerTx.kind.in_(("payout_sent", "payout_returned"))))
                             .all().__len__(), 1)

    def test_an_agreed_price_buys_one_pair(self):
        listing = self.publish(sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
        size = listing["sizes"][0]["id"]
        offer = self.post(f"/listings/{listing['id']}/offers", self.buyer, {"size_id": size, "amount_tiyn": 4_000_000})
        self.post(f"/offers/{offer.json()['id']}/accept", self.seller)
        rs = self.race(*[lambda i=i: self.post("/orders", self.buyer, {
            "listing_id": listing["id"], "size_id": size, "offer_id": offer.json()["id"]}, **{"Idempotency-Key": f"o{i}"})
            for i in range(N)])
        self.assertEqual([r.status_code for r in rs].count(201), 1, self.codes(rs))

    def test_one_payout_however_often_it_is_asked(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        self.c.put("/api/v1/me/payout-account", headers=self.h(self.seller), json={
            "holder_name": "ЖК Qadam Store", "iban": "kz86 125K ZT50 0410 0100",
            "tax_id": with_check_digit("90010130012")})
        rs = self.same(lambda: self.post("/me/payouts", self.seller))
        self.assertEqual([r.status_code for r in rs].count(201), 1, self.codes(rs))
        self.assertEqual(self.count(Payout), 1)

    def test_cancel_and_payment_at_once_end_in_one_state(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.race(lambda: self.post(f"/orders/{order['id']}/cancel", self.buyer), lambda: self.pay(order))
        with self.db() as db:
            o = db.get(Order, order["id"])
            status, owed = o.status, o.pending_refund_tiyn
        self.assertIn(status, ("PAID", "REFUND_PENDING"))
        self.assertEqual(self.kinds(order), ["payment_captured"])
        if status == "REFUND_PENDING":  # cancelled first: the payment that landed after is owed back in full
            self.assertEqual(owed, order["total_tiyn"])

    def test_an_agreed_price_ordered_while_a_new_offer_is_sent_stays_ordered(self):
        calls, offers = [], []
        for i in range(N // 2):  # several listings at once, so the two requests meet in every order
            listing = self.publish(title=f"Аяқкиім {i}", sizes=[{"label": "EU 42", "insole_cm": "26,5", "quantity": 5}])
            size = listing["sizes"][0]["id"]
            offer = self.post(f"/listings/{listing['id']}/offers", self.buyer,
                              {"size_id": size, "amount_tiyn": 4_000_000}).json()
            self.post(f"/offers/{offer['id']}/accept", self.seller)
            offers.append(offer["id"])
            calls += [lambda l=listing, s=size, o=offer: self.post("/orders", self.buyer, {
                          "listing_id": l["id"], "size_id": s, "offer_id": o["id"]}, **{"Idempotency-Key": f"a{o['id']}"}),
                      lambda l=listing, s=size: self.post(f"/listings/{l['id']}/offers", self.buyer,
                                                          {"size_id": s, "amount_tiyn": 4_100_000})]
        rs = self.race(*calls)
        with self.db() as db:
            for offer_id, order in zip(offers, rs[::2]):
                self.assertEqual(db.get(Offer, offer_id).status, "ordered" if order.status_code == 201 else "withdrawn")

    # Order steps

    def test_seller_steps_pressed_many_times_happen_once(self):
        _, order = self.ordered()
        self.post(f"/orders/{order['id']}/pay", self.buyer)
        self.pay(order)
        rs = self.same(lambda: self.post(f"/orders/{order['id']}/accept", self.seller))
        self.assertEqual([r.status_code for r in rs].count(200), 1, self.codes(rs))
        rs = self.same(lambda: self.post(f"/orders/{order['id']}/ship", self.seller, {"tracking_number": "KZ1"}))
        self.assertEqual([r.status_code for r in rs].count(200), 1, self.codes(rs))
        self.assertEqual(self.c.get(f"/api/v1/orders/{order['id']}", headers=self.h(self.buyer)).json()["status"],
                         "SHIPPED")
        for step in ("SELLER_ACCEPTED", "SHIPPED"):  # one step, one event, one message to the buyer
            self.assertEqual(self.count(OrderEvent, OrderEvent.order_id == order["id"], OrderEvent.to_status == step),
                             1, step)

    def test_one_review_however_often_it_is_sent(self):
        _, order = self.delivered()
        self.post(f"/orders/{order['id']}/confirm", self.buyer)
        rs = self.same(lambda: self.post(f"/orders/{order['id']}/review", self.buyer, {"rating": 5}))
        self.assertEqual([r.status_code for r in rs].count(201), 1, self.codes(rs))
        self.assertEqual(self.count(Review), 1)

    # Offers

    def test_an_offer_is_answered_once(self):
        listing = self.publish()
        offer = self.post(f"/listings/{listing['id']}/offers", self.buyer,
                          {"size_id": listing["sizes"][0]["id"], "amount_tiyn": 4_000_000}).json()
        rs = self.race(*[lambda: self.post(f"/offers/{offer['id']}/accept", self.seller)] * (N // 2),
                       *[lambda: self.post(f"/offers/{offer['id']}/decline", self.seller)] * (N // 2))
        self.assertEqual([r.status_code for r in rs].count(200), 1, self.codes(rs))

    # Things a person keeps one of

    def test_one_chat_per_listing_and_order(self):
        listing, order = self.ordered()
        self.same(lambda: self.post("/conversations", self.buyer, {"listing_id": listing["id"]}))
        self.same(lambda: self.post(f"/orders/{order['id']}/conversation", self.buyer))
        self.assertEqual(self.count(Conversation), 1)

    def test_favourites_and_follows_pressed_many_times_stay_one(self):
        listing = self.publish()
        self.same(lambda: self.post(f"/favorites/{listing['id']}", self.buyer))
        self.same(lambda: self.c.delete(f"/api/v1/favorites/{listing['id']}", headers=self.h(self.buyer)))
        self.same(lambda: self.post(f"/favorites/{listing['id']}", self.buyer))
        favs = self.c.get("/api/v1/favorites", headers=self.h(self.buyer)).json()["items"]
        self.assertEqual([f["id"] for f in favs], [listing["id"]])
        seller_id = listing["seller"]["id"]
        self.same(lambda: self.c.put(f"/api/v1/sellers/{seller_id}/follow", headers=self.h(self.buyer)))
        self.same(lambda: self.c.put(f"/api/v1/listings/{listing['id']}/sizes/{listing['sizes'][0]['id']}/alert",
                                     headers=self.h(self.buyer)))
        self.same(lambda: self.post(f"/listings/{listing['id']}/report", self.buyer,
                                    {"reason": "fake", "text": "Түпнұсқа емес сияқты"}))

    def test_a_promo_code_with_one_use_left_is_used_once(self):
        self.post("/me/promo-codes", self.seller, {"code": "ONCE", "percent": 10, "max_uses": 1})
        listings = [self.publish(title=f"Аяқкиім {i}") for i in range(N)]
        buyers = [self.login(f"+7701000020{i}") for i in range(N)]
        rs = self.race(*[lambda t=t, l=l: self.post("/orders", t, {
            "listing_id": l["id"], "size_id": l["sizes"][0]["id"], "promo_code": "ONCE", "delivery": ADDRESS},
            **{"Idempotency-Key": f"p-{l['id']}"}) for t, l in zip(buyers, listings)])
        discounted = [r for r in rs if r.status_code == 201 and r.json().get("promo_code") == "ONCE"]
        self.assertEqual(len(discounted), 1, [r.text[:120] for r in rs])
