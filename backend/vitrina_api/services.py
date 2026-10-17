"""Order, ledger and settlement operations on the database, built on vitrina_core rules."""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.money import (PROVIDER_CLEARING, CommissionRule, Entry, escrow, settlement_entries,
                                validate_entries)
from vitrina_core.orders import Actor, Order as CoreOrder, OrderStatus, TransitionError, transition

from .errors import ApiError
from .models import (AuditLog, LedgerEntry, LedgerTx, Listing, ListingSize, Notification, Order, OrderEvent,
                     StockAlert)


def aware(dt: datetime | None) -> datetime | None:
    """SQLite drops tzinfo; every stored time is UTC."""
    if dt is None or dt.tzinfo is not None:
        return dt
    return dt.replace(tzinfo=timezone.utc)


def total_tiyn(order: Order) -> int:
    return order.item_price_tiyn + order.delivery_price_tiyn


# Who hears about each order status, and what they read. "{id}" and "{tracking}" are filled in.
STATUS_NOTICES: dict[OrderStatus, tuple[tuple[str, ...], str, str]] = {
    OrderStatus.PAID: (("seller",), "Тапсырыс №{id} төленді. Қабылдаңыз немесе бас тартыңыз.",
                       "Заказ №{id} оплачен. Примите его или откажитесь."),
    OrderStatus.SELLER_ACCEPTED: (("buyer",), "Сатушы №{id} тапсырысты қабылдады.", "Продавец принял заказ №{id}."),
    OrderStatus.SHIPPED: (("buyer",), "Тапсырыс №{id} жіберілді. Трек-нөмір: {tracking}.",
                          "Заказ №{id} отправлен. Трек-номер: {tracking}."),
    OrderStatus.DELIVERED_PENDING_CONFIRMATION: (("buyer",), "Тапсырыс №{id} жеткізілді. Тексеріп, растаңыз.",
                                                 "Заказ №{id} доставлен. Проверьте и подтвердите получение."),
    OrderStatus.COMPLETED: (("buyer", "seller"), "Тапсырыс №{id} аяқталды.", "Заказ №{id} завершён."),
    OrderStatus.DISPUTED: (("buyer", "seller"), "Тапсырыс №{id} бойынша дау ашылды. Қолдау қызметі қарайды.",
                           "По заказу №{id} открыт спор. Его рассмотрит поддержка."),
    OrderStatus.RETURN_REQUESTED: (("seller",), "Сатып алушы №{id} тапсырысты қайтаруды сұрады.",
                                   "Покупатель запросил возврат заказа №{id}."),
    OrderStatus.REFUND_PENDING: (("buyer", "seller"), "Тапсырыс №{id} бойынша ақша қайтарылуда.",
                                 "По заказу №{id} деньги возвращаются."),
    OrderStatus.REFUNDED: (("buyer",), "Тапсырыс №{id} бойынша ақша қайтарылды.", "По заказу №{id} деньги возвращены."),
    OrderStatus.CANCELLED: (("buyer", "seller"), "Тапсырыс №{id} жойылды.", "Заказ №{id} отменён."),
}


def notify(db: Session, user_id: int, kind: str, text: str, text_ru: str, *, order_id: int | None = None,
           conversation_id: int | None = None, listing_id: int | None = None) -> None:
    db.add(Notification(user_id=user_id, kind=kind, text_kk=text[:300], text_ru=text_ru[:300], order_id=order_id,
                        conversation_id=conversation_id, listing_id=listing_id))


def notify_status(db: Session, order: Order, actor_user_id: int | None) -> None:
    rule = STATUS_NOTICES.get(OrderStatus(order.status))
    if rule is None:
        return
    roles, template, template_ru = rule
    values = {"id": order.id, "tracking": order.tracking_number or "—"}
    text, text_ru = template.format(**values), template_ru.format(**values)
    for role in roles:
        user_id = order.buyer_id if role == "buyer" else order.seller_id
        if user_id != actor_user_id:  # nobody is told about their own action
            notify(db, user_id, "order_status", text, text_ru, order_id=order.id)


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
    notify_status(db, order, user_id)


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
    tell_back_in_stock(db, listing)


def tell_back_in_stock(db: Session, listing: Listing) -> None:
    """Notify buyers waiting for a size that is on sale again, once; call wherever stock or status can change."""
    if listing.status != "published":
        return
    in_stock = {s.id: s.label for s in listing.sizes if s.quantity > 0}
    for alert in db.scalars(select(StockAlert).where(StockAlert.listing_id == listing.id)).all():
        if alert.size_id in in_stock:
            label = in_stock[alert.size_id]
            notify(db, alert.user_id, "back_in_stock", f"«{listing.title}», {label} өлшемі қайта сатылымда.",
                   f"«{listing.title}», размер {label} снова в продаже.", listing_id=listing.id)
            db.delete(alert)


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
