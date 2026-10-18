import json
import re
import unittest
from pathlib import Path
from datetime import datetime, timedelta, timezone

from vitrina_core.catalog import compute_bounds, normalize_query, Segment, MIN_SAMPLE
from vitrina_core.colors import COLORS, WORDS, canonical_color, color_query
from vitrina_core.money import (
    CommissionRule, Entry, Ledger, LedgerError, PLATFORM_FEE, PROVIDER_CLEARING,
    buyer_refund, escrow, format_tenge, record_payment, seller_payable, settle, tenge_to_tiyn,
)
from vitrina_core.orders import Actor, Order, OrderStatus as S, TransitionError, allowed_next, transition
from vitrina_core.webhooks import PaymentWebhookHandler, WebhookRejected, sign

T0 = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
RULE = CommissionRule(version="2026-10-pilot", rate_bp=500)  # 5%, hypothetical
SECRET = b"test-secret"


def new_order(**kw):
    return Order(id="o1", buyer_id="b1", seller_id="s1",
                 item_price_tiyn=kw.pop("item", tenge_to_tiyn(45_000)),
                 delivery_price_tiyn=kw.pop("delivery", tenge_to_tiyn(1_500)), **kw)


def paid_order():
    o = new_order()
    transition(o, S.PAYMENT_PENDING, Actor.BUYER, now=T0)
    transition(o, S.PAID, Actor.SYSTEM, now=T0)
    return o


def delivered_order():
    o = paid_order()
    transition(o, S.SELLER_ACCEPTED, Actor.SELLER, now=T0)
    transition(o, S.SHIPPED, Actor.SELLER, now=T0, tracking_number="KZ123")
    transition(o, S.DELIVERED_PENDING_CONFIRMATION, Actor.SYSTEM, now=T0 + timedelta(days=2))
    return o


class OrderStateMachineTests(unittest.TestCase):
    def test_happy_path(self):
        o = delivered_order()
        transition(o, S.COMPLETED, Actor.BUYER, now=T0 + timedelta(days=3))
        self.assertEqual(o.status, S.COMPLETED)
        self.assertEqual(len(o.history), 6)

    def test_buyer_cannot_mark_paid(self):
        o = new_order()
        transition(o, S.PAYMENT_PENDING, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.PAID, Actor.BUYER)

    def test_unpaid_order_cannot_be_delivered_or_shipped(self):
        o = new_order()
        for target in (S.DELIVERED_PENDING_CONFIRMATION, S.SHIPPED, S.COMPLETED):
            with self.assertRaises(TransitionError):
                transition(o, target, Actor.SUPPORT)

    def test_dispute_cannot_jump_to_completed_without_support_reason(self):
        o = delivered_order()
        transition(o, S.DISPUTED, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.COMPLETED, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.COMPLETED, Actor.SUPPORT)  # no reason
        transition(o, S.COMPLETED, Actor.SUPPORT, reason="Photos match the listing")
        self.assertEqual(o.status, S.COMPLETED)

    def test_return_request_cannot_complete_directly(self):
        o = delivered_order()
        transition(o, S.RETURN_REQUESTED, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.COMPLETED, Actor.SUPPORT, reason="x")

    def test_shipping_requires_tracking(self):
        o = paid_order()
        transition(o, S.SELLER_ACCEPTED, Actor.SELLER)
        with self.assertRaises(TransitionError):
            transition(o, S.SHIPPED, Actor.SELLER, tracking_number="  ")

    def test_auto_complete_only_after_window(self):
        o = delivered_order()
        window = timedelta(days=5)
        with self.assertRaises(TransitionError):
            transition(o, S.COMPLETED, Actor.SCHEDULER, now=T0 + timedelta(days=6), confirm_after=window)
        transition(o, S.COMPLETED, Actor.SCHEDULER, now=T0 + timedelta(days=7), confirm_after=window)
        self.assertEqual(o.status, S.COMPLETED)

    def test_auto_complete_blocked_by_open_dispute(self):
        o = delivered_order()
        transition(o, S.DISPUTED, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.COMPLETED, Actor.SCHEDULER, now=T0 + timedelta(days=30),
                       confirm_after=timedelta(days=5))

    def test_terminal_states_are_final(self):
        o = new_order()
        transition(o, S.CANCELLED, Actor.BUYER)
        with self.assertRaises(TransitionError):
            transition(o, S.PAYMENT_PENDING, Actor.BUYER)
        for actor in (Actor.BUYER, Actor.SELLER, Actor.SUPPORT, Actor.SCHEDULER):
            with self.assertRaises(TransitionError):
                transition(o, S.REFUND_PENDING, actor)

    def test_payment_arriving_after_cancel_is_refunded(self):
        o = new_order()
        transition(o, S.CANCELLED, Actor.SCHEDULER)
        transition(o, S.REFUND_PENDING, Actor.SYSTEM)
        self.assertEqual(o.status, S.REFUND_PENDING)

    def test_paid_order_is_refunded_not_cancelled(self):
        o = paid_order()
        self.assertNotIn(S.CANCELLED, allowed_next(o.status, Actor.BUYER))
        self.assertIn(S.REFUND_PENDING, allowed_next(o.status, Actor.BUYER))

    def test_float_prices_rejected(self):
        with self.assertRaises(ValueError):
            Order(id="x", buyer_id="b", seller_id="s", item_price_tiyn=450.5)


class MoneyTests(unittest.TestCase):
    def test_parse_and_format(self):
        self.assertEqual(tenge_to_tiyn("45 000"), 4_500_000)
        self.assertEqual(tenge_to_tiyn("19,99"), 1_999)
        self.assertEqual(format_tenge(4_500_000), "45 000 ₸")
        with self.assertRaises(ValueError):
            tenge_to_tiyn("1.234")

    def test_commission_rounding_and_min(self):
        self.assertEqual(RULE.fee_for(4_500_000), 225_000)
        self.assertEqual(CommissionRule("v", 300).fee_for(1_001), 30)   # 30.03 -> 30
        self.assertEqual(CommissionRule("v", 350).fee_for(1_000), 35)
        self.assertEqual(CommissionRule("v", 500, min_fee_tiyn=20_000).fee_for(100_000), 20_000)

    def test_unbalanced_rejected(self):
        with self.assertRaises(LedgerError):
            Ledger().post(idempotency_key="k", order_id="o", kind="x", actor="t",
                          entries=[Entry("a", debit=100), Entry("b", credit=99)])

    def test_completion_split(self):
        o = delivered_order()
        led = Ledger()
        record_payment(led, order_id=o.id, amount_tiyn=o.total_tiyn, provider_event_id="e1")
        settle(led, order_id=o.id, seller_id=o.seller_id, buyer_id=o.buyer_id,
               item_price_tiyn=o.item_price_tiyn, refund_tiyn=0, rule=RULE, actor="buyer")
        self.assertEqual(led.balance(escrow(o.id)), 0)
        self.assertEqual(led.balance(PLATFORM_FEE), 225_000)
        self.assertEqual(led.balance(seller_payable("s1")), 4_650_000 - 225_000)
        self.assertEqual(-led.balance(PROVIDER_CLEARING), 4_650_000)

    def test_full_refund_takes_no_fee(self):
        o = delivered_order()
        led = Ledger()
        record_payment(led, order_id=o.id, amount_tiyn=o.total_tiyn, provider_event_id="e1")
        tx = settle(led, order_id=o.id, seller_id="s1", buyer_id="b1", item_price_tiyn=o.item_price_tiyn,
                    refund_tiyn=o.total_tiyn, rule=RULE, actor="support", reason="not delivered")
        self.assertEqual(tx.kind, "refund_full")
        self.assertEqual(led.balance(buyer_refund("b1")), o.total_tiyn)
        self.assertEqual(led.balance(PLATFORM_FEE), 0)

    def test_partial_refund(self):
        o = delivered_order()
        led = Ledger()
        record_payment(led, order_id=o.id, amount_tiyn=o.total_tiyn, provider_event_id="e1")
        settle(led, order_id=o.id, seller_id="s1", buyer_id="b1", item_price_tiyn=o.item_price_tiyn,
               refund_tiyn=1_000_000, rule=RULE, actor="support", reason="hidden scuff")
        kept = o.total_tiyn - 1_000_000
        self.assertEqual(led.balance(PLATFORM_FEE), RULE.fee_for(min(kept, o.item_price_tiyn)))
        self.assertEqual(led.balance(seller_payable("s1")) + led.balance(PLATFORM_FEE), kept)

    def test_settlement_is_idempotent_and_cannot_overdraw(self):
        led = Ledger()
        record_payment(led, order_id="o1", amount_tiyn=10_000, provider_event_id="e1")
        a = settle(led, order_id="o1", seller_id="s1", buyer_id="b1", item_price_tiyn=10_000,
                   refund_tiyn=0, rule=RULE, actor="buyer")
        b = settle(led, order_id="o1", seller_id="s1", buyer_id="b1", item_price_tiyn=10_000,
                   refund_tiyn=0, rule=RULE, actor="buyer")
        self.assertIs(a, b)
        self.assertEqual(len(led.transactions), 2)
        with self.assertRaises(LedgerError):
            settle(Ledger(), order_id="o2", seller_id="s", buyer_id="b", item_price_tiyn=1,
                   refund_tiyn=0, rule=RULE, actor="buyer")

    def test_reversal_needs_reason_and_restores_balances(self):
        led = Ledger()
        tx = record_payment(led, order_id="o1", amount_tiyn=10_000, provider_event_id="e1")
        with self.assertRaises(LedgerError):
            led.reverse(tx.id, actor="admin:7", reason=" ")
        led.reverse(tx.id, actor="admin:7", reason="duplicate capture confirmed by provider")
        self.assertEqual(led.balance(escrow("o1")), 0)
        self.assertEqual(len(led.transactions), 2)  # original kept, nothing edited


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.order = new_order()
        transition(self.order, S.PAYMENT_PENDING, Actor.BUYER)
        self.ledger = Ledger()
        self.h = PaymentWebhookHandler(SECRET, self.ledger, {"o1": self.order})
        self.ts = 1_790_000_000

    def body(self, **over):
        ev = {"id": "evt_1", "type": "payment.succeeded", "order_id": "o1",
              "amount_tiyn": self.order.total_tiyn, "currency": "KZT"}
        ev.update(over)
        return json.dumps(ev).encode()

    def send(self, body, sig=None, ts=None):
        ts = ts or self.ts
        return self.h.handle(ts, body, sig or sign(SECRET, ts, body), now=self.ts)

    def test_valid_payment_applies_once(self):
        b = self.body()
        self.assertEqual(self.send(b), "applied")
        self.assertEqual(self.send(b), "duplicate")
        self.assertEqual(self.order.status, S.PAID)
        self.assertEqual(self.ledger.balance(escrow("o1")), self.order.total_tiyn)
        self.assertEqual(len(self.ledger.transactions), 1)

    def test_second_event_id_for_same_order_does_not_double_count(self):
        self.send(self.body())
        self.assertEqual(self.send(self.body(id="evt_2")), "duplicate")
        self.assertEqual(self.ledger.balance(escrow("o1")), self.order.total_tiyn)

    def test_bad_signature_rejected(self):
        with self.assertRaises(WebhookRejected):
            self.send(self.body(), sig="0" * 64)
        self.assertEqual(self.order.status, S.PAYMENT_PENDING)

    def test_stale_timestamp_rejected(self):
        with self.assertRaises(WebhookRejected):
            self.send(self.body(), ts=self.ts - 3600)

    def test_wrong_amount_rejected(self):
        with self.assertRaises(WebhookRejected):
            self.send(self.body(amount_tiyn=1))
        self.assertEqual(self.order.status, S.PAYMENT_PENDING)

    def test_unknown_order_rejected(self):
        with self.assertRaises(WebhookRejected):
            self.send(self.body(order_id="nope"))


class CatalogTests(unittest.TestCase):
    def test_segments_need_enough_data(self):
        self.assertIsNone(compute_bounds("sneakers", [1_000_000] * (MIN_SAMPLE - 1)))
        prices = list(range(1_000_000, 1_000_000 + MIN_SAMPLE * 10_000, 10_000))
        b = compute_bounds("sneakers", prices)
        self.assertEqual(b.segment_for(prices[0]), Segment.ECONOMY)
        self.assertEqual(b.segment_for(prices[-1]), Segment.LUXURY)

    def test_query_normalization(self):
        self.assertEqual(normalize_query("Кроссовки  НАЙК"), "krossovki nike")
        self.assertEqual(normalize_query("нью баланс 574"), "new balance 574")
        self.assertEqual(normalize_query("unbox"), "unbox")  # 'nb' only as a whole word
        self.assertEqual(normalize_query("қысқы етік"), "qysqy etik")



APP_COLORS = Path(__file__).resolve().parents[2] / "app" / "lib" / "colors.dart"


class ColorTests(unittest.TestCase):
    def test_a_colour_typed_in_any_word_is_stored_by_its_kazakh_name(self):
        for typed in ("Черный", " чёрный ", "BLACK", "қара", "кара", "черные", "\u200bчерный"):
            self.assertEqual(canonical_color(typed), "қара", typed)
        self.assertEqual(canonical_color("Темно-синий"), "қою көк")
        self.assertEqual(canonical_color("бело-черный"), "қара-ақ")
        self.assertEqual(canonical_color("құм"), "құм түсті")  # the earlier name still maps
        self.assertEqual(canonical_color("  мраморный  с  белым "), "мраморный с белым")  # not listed: as typed
        self.assertEqual(canonical_color("\u200b\u200e"), "")  # invisible characters are no colour

    def test_a_query_names_colours_as_they_are_stored(self):
        self.assertEqual(color_query("Черные кроссовки Nike"), "қара кроссовки nike")
        self.assertEqual(color_query("белая обувь black/white"), "ақ обувь қара-ақ")
        self.assertEqual(color_query("low top golden"), "low top golden")  # only whole words

    def test_no_word_names_two_colours(self):
        words = [w for name, others in COLORS.items() for w in (name, *others)]
        self.assertEqual(len(words), len(set(words)))
        self.assertEqual(len(WORDS), len({w for w in WORDS}))

    @unittest.skipUnless(APP_COLORS.exists(), "the app is not next to the backend here")
    def test_the_app_offers_the_same_colours(self):
        dart = APP_COLORS.read_text(encoding="utf-8")
        block = dart[dart.index("const shoeColors"):dart.index("};", dart.index("const shoeColors"))]
        self.assertEqual(re.findall(r"^  '([^']+)': Color", block, re.M), list(COLORS))

if __name__ == "__main__":
    unittest.main()
