"""Order state machine.

Every status change goes through `transition`, which checks both the edge and
the actor allowed to take it. Payment-related edges belong to SYSTEM (verified
provider events), never to the buyer's client.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum


class OrderStatus(str, Enum):
    CREATED = "CREATED"
    PAYMENT_PENDING = "PAYMENT_PENDING"
    PAID = "PAID"
    SELLER_ACCEPTED = "SELLER_ACCEPTED"
    PREPARING = "PREPARING"
    SHIPPED = "SHIPPED"
    IN_TRANSIT = "IN_TRANSIT"
    DELIVERED_PENDING_CONFIRMATION = "DELIVERED_PENDING_CONFIRMATION"
    COMPLETED = "COMPLETED"
    DISPUTED = "DISPUTED"
    RETURN_REQUESTED = "RETURN_REQUESTED"
    REFUND_PENDING = "REFUND_PENDING"
    REFUNDED = "REFUNDED"
    CANCELLED = "CANCELLED"


class Actor(str, Enum):
    BUYER = "buyer"
    SELLER = "seller"
    SYSTEM = "system"        # verified provider / courier events
    SCHEDULER = "scheduler"  # timed rules (auto-complete, expiry)
    SUPPORT = "support"


S, A = OrderStatus, Actor

# (from, to) -> actors allowed to make that move
TRANSITIONS: dict[tuple[OrderStatus, OrderStatus], frozenset[Actor]] = {
    (S.CREATED, S.PAYMENT_PENDING): frozenset({A.BUYER}),
    (S.CREATED, S.CANCELLED): frozenset({A.BUYER, A.SYSTEM, A.SCHEDULER}),
    (S.PAYMENT_PENDING, S.PAID): frozenset({A.SYSTEM}),
    (S.PAYMENT_PENDING, S.CANCELLED): frozenset({A.BUYER, A.SYSTEM, A.SCHEDULER}),
    (S.PAID, S.SELLER_ACCEPTED): frozenset({A.SELLER}),
    (S.PAID, S.REFUND_PENDING): frozenset({A.BUYER, A.SELLER, A.SUPPORT, A.SCHEDULER}),
    (S.SELLER_ACCEPTED, S.PREPARING): frozenset({A.SELLER}),
    (S.SELLER_ACCEPTED, S.SHIPPED): frozenset({A.SELLER}),
    (S.SELLER_ACCEPTED, S.REFUND_PENDING): frozenset({A.SELLER, A.SUPPORT}),
    (S.PREPARING, S.SHIPPED): frozenset({A.SELLER}),
    (S.PREPARING, S.REFUND_PENDING): frozenset({A.SELLER, A.SUPPORT}),
    (S.SHIPPED, S.IN_TRANSIT): frozenset({A.SYSTEM, A.SUPPORT}),
    (S.SHIPPED, S.DELIVERED_PENDING_CONFIRMATION): frozenset({A.SYSTEM, A.SUPPORT}),
    (S.SHIPPED, S.DISPUTED): frozenset({A.BUYER}),
    (S.IN_TRANSIT, S.DELIVERED_PENDING_CONFIRMATION): frozenset({A.SYSTEM, A.SUPPORT}),
    (S.IN_TRANSIT, S.DISPUTED): frozenset({A.BUYER}),
    (S.DELIVERED_PENDING_CONFIRMATION, S.COMPLETED): frozenset({A.BUYER, A.SCHEDULER}),
    (S.DELIVERED_PENDING_CONFIRMATION, S.DISPUTED): frozenset({A.BUYER}),
    (S.DELIVERED_PENDING_CONFIRMATION, S.RETURN_REQUESTED): frozenset({A.BUYER}),
    (S.RETURN_REQUESTED, S.REFUND_PENDING): frozenset({A.SELLER, A.SUPPORT}),
    (S.RETURN_REQUESTED, S.DISPUTED): frozenset({A.BUYER, A.SELLER}),
    (S.DISPUTED, S.COMPLETED): frozenset({A.SUPPORT}),
    (S.DISPUTED, S.REFUND_PENDING): frozenset({A.SUPPORT}),
    (S.REFUND_PENDING, S.REFUNDED): frozenset({A.SYSTEM}),
    # The one way out of a final status: the provider reports a payment for an order that was already cancelled
    # (the buyer paid in a tab left open). The money is real, so it goes back to the buyer.
    (S.CANCELLED, S.REFUND_PENDING): frozenset({A.SYSTEM}),
}
LATE_PAYMENT = (S.CANCELLED, S.REFUND_PENDING)

TERMINAL = frozenset({S.COMPLETED, S.REFUNDED, S.CANCELLED})
# Support decisions on money must carry a written reason (audit requirement).
REASON_REQUIRED = frozenset({(S.DISPUTED, S.COMPLETED), (S.DISPUTED, S.REFUND_PENDING)})


class TransitionError(Exception):
    pass


@dataclass
class HistoryEntry:
    at: datetime
    actor: Actor
    from_status: OrderStatus
    to_status: OrderStatus
    reason: str | None


@dataclass
class Order:
    id: str
    buyer_id: str
    seller_id: str
    item_price_tiyn: int
    delivery_price_tiyn: int = 0
    status: OrderStatus = S.CREATED
    tracking_number: str | None = None
    delivered_at: datetime | None = None
    history: list[HistoryEntry] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not isinstance(self.item_price_tiyn, int) or self.item_price_tiyn <= 0:
            raise ValueError("item_price_tiyn must be a positive integer (tiyn, not float tenge)")
        if not isinstance(self.delivery_price_tiyn, int) or self.delivery_price_tiyn < 0:
            raise ValueError("delivery_price_tiyn must be a non-negative integer")

    @property
    def total_tiyn(self) -> int:
        return self.item_price_tiyn + self.delivery_price_tiyn


def allowed_next(status: OrderStatus, actor: Actor) -> list[OrderStatus]:
    return [to for (frm, to), actors in TRANSITIONS.items() if frm == status and actor in actors]


def transition(
    order: Order,
    to: OrderStatus,
    actor: Actor,
    *,
    now: datetime | None = None,
    reason: str | None = None,
    tracking_number: str | None = None,
    confirm_after: timedelta | None = None,
) -> Order:
    now = now or datetime.now(timezone.utc)
    frm = order.status
    if frm in TERMINAL and (frm, to) != LATE_PAYMENT:
        raise TransitionError(f"order {order.id} is final ({frm.value})")
    actors = TRANSITIONS.get((frm, to))
    if actors is None:
        raise TransitionError(f"{frm.value} -> {to.value} is not a valid transition")
    if actor not in actors:
        raise TransitionError(f"{actor.value} may not move {frm.value} -> {to.value}")
    if (frm, to) in REASON_REQUIRED and not (reason and reason.strip()):
        raise TransitionError("a written reason is required for this decision")
    if to == S.SHIPPED:
        if not (tracking_number and tracking_number.strip()):
            raise TransitionError("tracking number is required to mark as shipped")
        order.tracking_number = tracking_number.strip()
    if to == S.COMPLETED and actor == A.SCHEDULER:
        if confirm_after is None or order.delivered_at is None:
            raise TransitionError("auto-complete needs delivered_at and a confirmation window")
        if now < order.delivered_at + confirm_after:
            raise TransitionError("confirmation window has not passed yet")
    if to == S.DELIVERED_PENDING_CONFIRMATION:
        order.delivered_at = now

    order.history.append(HistoryEntry(now, actor, frm, to, reason))
    order.status = to
    return order
