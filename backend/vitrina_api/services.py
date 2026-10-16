"""Order, ledger and settlement operations on the database, built on vitrina_core rules."""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.money import (PROVIDER_CLEARING, CommissionRule, Entry, escrow, settlement_entries,
                                validate_entries)
from vitrina_core.orders import Actor, Order as CoreOrder, OrderStatus, TransitionError, transition

from .errors import ApiError
from .models import AuditLog, LedgerEntry, LedgerTx, Listing, ListingSize, Order, OrderEvent


def aware(dt: datetime | None) -> datetime | None:
    """SQLite drops tzinfo; every stored time is UTC."""
    if dt is None or dt.tzinfo is not None:
        return dt
    return dt.replace(tzinfo=timezone.utc)


def total_tiyn(order: Order) -> int:
    return order.item_price_tiyn + order.delivery_price_tiyn


def move(db: Session, order: Order, to: OrderStatus, actor: Actor, *, user_id: int | None = None,
         reason: str | None = None, tracking_number: str | None = None, now: datetime | None = None,
         confirm_after=None) -> None:
    core = CoreOrder(id=str(order.id), buyer_id=str(order.buyer_id), seller_id=str(order.seller_id),
                     item_price_tiyn=order.item_price_tiyn, delivery_price_tiyn=order.delivery_price_tiyn,
                     status=OrderStatus(order.status), tracking_number=order.tracking_number,
                     delivered_at=aware(order.delivered_at))
    frm = order.status
    try:
        transition(core, to, actor, now=now, reason=reason, tracking_number=tracking_number,
                   confirm_after=confirm_after)
    except TransitionError as exc:
        msg = str(exc)
        code = "tracking_required" if "tracking" in msg else "reason_required" if "reason" in msg else "invalid_transition"
        raise ApiError(409 if code == "invalid_transition" else 422, code, msg) from exc
    order.status = core.status.value
    order.tracking_number = core.tracking_number
    order.delivered_at = core.delivered_at
    db.add(OrderEvent(order_id=order.id, actor=actor.value, actor_user_id=user_id, from_status=frm,
                      to_status=order.status, reason=reason, at=now or datetime.now(timezone.utc)))


def post_tx(db: Session, *, key: str, order_id: int | None, kind: str, entries: list[Entry], actor: str,
            reason: str | None = None) -> LedgerTx:
    existing = db.scalar(select(LedgerTx).where(LedgerTx.idempotency_key == key))
    if existing is not None:
        return existing
    validate_entries(entries)
    tx = LedgerTx(idempotency_key=key, order_id=order_id, kind=kind, actor=actor, reason=reason,
                  entries=[LedgerEntry(account=e.account, debit=e.debit, credit=e.credit) for e in entries])
    db.add(tx)
    db.flush()
    return tx


def balance(db: Session, account: str) -> int:
    value = db.scalar(select(func.coalesce(func.sum(LedgerEntry.credit - LedgerEntry.debit), 0))
                      .where(LedgerEntry.account == account))
    return int(value or 0)


def record_payment(db: Session, order: Order, event_id: str) -> None:
    amount = total_tiyn(order)
    post_tx(db, key=f"payment:{event_id}", order_id=order.id, kind="payment_captured", actor="system",
            entries=[Entry(PROVIDER_CLEARING, debit=amount), Entry(escrow(str(order.id)), credit=amount)])


def settle(db: Session, order: Order, *, refund_tiyn: int, rule: CommissionRule, actor: str,
           reason: str | None = None) -> LedgerTx:
    key = f"settle:{order.id}"
    existing = db.scalar(select(LedgerTx).where(LedgerTx.idempotency_key == key))
    if existing is not None:
        return existing
    kind, entries = settlement_entries(order_id=str(order.id), seller_id=str(order.seller_id),
                                       buyer_id=str(order.buyer_id), held_tiyn=balance(db, escrow(str(order.id))),
                                       item_price_tiyn=order.item_price_tiyn, refund_tiyn=refund_tiyn, rule=rule)
    return post_tx(db, key=key, order_id=order.id, kind=kind, entries=entries, actor=actor, reason=reason)


def restock(db: Session, order: Order) -> None:
    size = db.get(ListingSize, order.size_id)
    size.quantity += 1
    listing = db.get(Listing, order.listing_id)
    if listing.status == "sold":
        listing.status = "published"


def audit(db: Session, user_id: int | None, action: str, target: str, reason: str | None = None) -> None:
    db.add(AuditLog(actor_user_id=user_id, action=action, target=target, reason=reason))


def run_auto_complete(db: Session, *, now: datetime, window, rule: CommissionRule) -> list[int]:
    """Scheduler job: complete delivered orders whose confirmation window passed with no dispute."""
    done = []
    rows = db.scalars(select(Order).where(Order.status == OrderStatus.DELIVERED_PENDING_CONFIRMATION.value)).all()
    for order in rows:
        if now < aware(order.delivered_at) + window:
            continue
        move(db, order, OrderStatus.COMPLETED, Actor.SCHEDULER, now=now, confirm_after=window)
        settle(db, order, refund_tiyn=0, rule=rule, actor="scheduler")
        done.append(order.id)
    db.commit()
    return done
