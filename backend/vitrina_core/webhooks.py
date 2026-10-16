"""Payment provider webhook verification and idempotent processing.

The real provider's signature scheme is not known yet; this implements the
common HMAC-SHA256 + timestamp pattern behind one function so it can be swapped
once a provider is chosen. Payment status never comes from the buyer's app.
"""
from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from datetime import datetime, timezone

from .money import Ledger, record_payment
from .orders import Actor, Order, OrderStatus, transition

MAX_SKEW_SECONDS = 300


class WebhookRejected(Exception):
    pass


def sign(secret: bytes, timestamp: int, body: bytes) -> str:
    return hmac.new(secret, f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()


def verify(secret: bytes, timestamp: int, body: bytes, signature: str, *, now: int | None = None) -> None:
    now = int(datetime.now(timezone.utc).timestamp()) if now is None else now
    if abs(now - timestamp) > MAX_SKEW_SECONDS:
        raise WebhookRejected("stale or future timestamp")
    if not hmac.compare_digest(sign(secret, timestamp, body), signature):
        raise WebhookRejected("bad signature")


@dataclass
class PaymentWebhookHandler:
    secret: bytes
    ledger: Ledger
    orders: dict[str, Order]
    currency: str = "KZT"

    def __post_init__(self) -> None:
        self._seen: set[str] = set()

    def handle(self, timestamp: int, body: bytes, signature: str, *, now: int | None = None) -> str:
        verify(self.secret, timestamp, body, signature, now=now)
        try:
            event = json.loads(body)
            event_id, kind = str(event["id"]), event["type"]
            order_id, amount, currency = event["order_id"], event["amount_tiyn"], event["currency"]
        except (ValueError, KeyError, TypeError) as exc:
            raise WebhookRejected(f"malformed event: {exc}") from exc
        if event_id in self._seen:
            return "duplicate"
        order = self.orders.get(order_id)
        if order is None:
            raise WebhookRejected("unknown order")
        if kind != "payment.succeeded":
            self._seen.add(event_id)
            return "ignored"
        if not isinstance(amount, int) or amount != order.total_tiyn or currency != self.currency:
            raise WebhookRejected("amount or currency does not match the order")
        if order.status == OrderStatus.PAID:
            self._seen.add(event_id)
            return "duplicate"
        record_payment(self.ledger, order_id=order.id, amount_tiyn=amount, provider_event_id=event_id)
        transition(order, OrderStatus.PAID, Actor.SYSTEM)
        self._seen.add(event_id)
        return "applied"
