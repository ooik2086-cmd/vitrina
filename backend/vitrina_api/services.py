"""Order, ledger and settlement operations on the database, built on vitrina_core rules."""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.orm import Session

from vitrina_core.money import (PROVIDER_CLEARING, CommissionRule, Entry, buyer_refund, escrow, settlement_entries,
                                validate_entries)
from vitrina_core.orders import Actor, Order as CoreOrder, OrderStatus, TransitionError, transition

from .errors import ApiError
from .models import (AuditLog, Block, LedgerEntry, LedgerTx, Listing, ListingSize, Notification, Order, OrderEvent,
                     Review, StockAlert, User)

log = logging.getLogger("vitrina.services")


def aware(dt: datetime | None) -> datetime | None:
    """SQLite drops tzinfo; every stored time is UTC."""
    if dt is None or dt.tzinfo is not None:
        return dt
    return dt.replace(tzinfo=timezone.utc)


def total_tiyn(order: Order) -> int:
    return order.item_price_tiyn + order.delivery_price_tiyn


# Who hears about each order status, and what they read. "{id}" and "{tracking}" are filled in.
STATUS_NOTICES: dict[OrderStatus, tuple[tuple[str, ...], str, str, str]] = {
    OrderStatus.PAID: (("seller",), "Тапсырыс №{id} төленді. Қабылдаңыз немесе бас тартыңыз.",
                       "Заказ №{id} оплачен. Примите его или откажитесь.",
                       "Order No. {id} is paid. Accept or decline it."),
    OrderStatus.SELLER_ACCEPTED: (("buyer",), "Сатушы №{id} тапсырысты қабылдады.", "Продавец принял заказ №{id}.",
                                  "The seller accepted order No. {id}."),
    OrderStatus.SHIPPED: (("buyer",), "Тапсырыс №{id} жіберілді. Трек-нөмір: {tracking}.",
                          "Заказ №{id} отправлен. Трек-номер: {tracking}.",
                          "Order No. {id} has shipped. Tracking number: {tracking}."),
    OrderStatus.DELIVERED_PENDING_CONFIRMATION: (("buyer",), "Тапсырыс №{id} жеткізілді. Тексеріп, растаңыз.",
                                                 "Заказ №{id} доставлен. Проверьте и подтвердите получение.",
                                                 "Order No. {id} was delivered. Check it and confirm receipt."),
    OrderStatus.COMPLETED: (("buyer", "seller"), "Тапсырыс №{id} аяқталды.", "Заказ №{id} завершён.",
                            "Order No. {id} is complete."),
    OrderStatus.DISPUTED: (("buyer", "seller"), "Тапсырыс №{id} бойынша дау ашылды. Қолдау қызметі қарайды.",
                           "По заказу №{id} открыт спор. Его рассмотрит поддержка.",
                           "A dispute was opened on order No. {id}. Support will review it."),
    OrderStatus.RETURN_REQUESTED: (("seller",), "Сатып алушы №{id} тапсырысты қайтаруды сұрады.",
                                   "Покупатель запросил возврат заказа №{id}.",
                                   "The buyer asked to return order No. {id}."),
    OrderStatus.REFUND_PENDING: (("buyer", "seller"), "Тапсырыс №{id} бойынша ақша қайтарылуда.",
                                 "По заказу №{id} деньги возвращаются.",
                                 "The money for order No. {id} is being refunded."),
    OrderStatus.REFUNDED: (("buyer",), "Тапсырыс №{id} бойынша ақша қайтарылды.", "По заказу №{id} деньги возвращены.",
                           "The money for order No. {id} was refunded."),
    OrderStatus.CANCELLED: (("buyer", "seller"), "Тапсырыс №{id} жойылды.", "Заказ №{id} отменён.",
                            "Order No. {id} was cancelled."),
}


# Alerts a person may turn off. Orders, payments, chat, offers and staff decisions always arrive.
OPTIONAL_KINDS = ("price_drop", "saved_search", "followed_shop", "back_in_stock")


def muted(user: User | None) -> set[str]:
    return set((user.muted_kinds or "").split(",")) - {""} if user else set()


def blocked_between(db: Session, a: int, b: int) -> bool:
    return db.scalar(select(Block.id).where(or_(and_(Block.user_id == a, Block.blocked_id == b),
                                                and_(Block.user_id == b, Block.blocked_id == a))).limit(1)) is not None


def ensure_not_blocked(db: Session, a: int, b: int) -> None:
    """The same answer whichever side blocked, so nobody learns they were blocked by probing."""
    if blocked_between(db, a, b):
        raise ApiError(403, "blocked")


def notify(db: Session, user_id: int, kind: str, text: str, text_ru: str, text_en: str, *, order_id: int | None = None,
           conversation_id: int | None = None, listing_id: int | None = None) -> None:
    if kind in OPTIONAL_KINDS and kind in muted(db.get(User, user_id)):
        return
    db.add(Notification(user_id=user_id, kind=kind, text_kk=text[:300], text_ru=text_ru[:300], text_en=text_en[:300],
                        order_id=order_id,
                        conversation_id=conversation_id, listing_id=listing_id))


def notify_status(db: Session, order: Order, actor_user_id: int | None) -> None:
    rule = STATUS_NOTICES.get(OrderStatus(order.status))
    if rule is None:
        return
    roles, template, template_ru, template_en = rule
    values = {"id": order.id, "tracking": order.tracking_number or "—"}
    text, text_ru, text_en = template.format(**values), template_ru.format(**values), template_en.format(**values)
    for role in roles:
        user_id = order.buyer_id if role == "buyer" else order.seller_id
        if user_id != actor_user_id:  # nobody is told about their own action
            notify(db, user_id, "order_status", text, text_ru, text_en, order_id=order.id)


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


def notify_sold_out(db: Session, order: Order) -> None:
    """Once a paid order takes the last pair of a size, the seller hears it, so a pair still on the shelf is
    put back on sale. An unpaid order is not news: it may be cancelled and give the pair back."""
    size = db.get(ListingSize, order.size_id)
    if size is None or size.quantity > 0:
        return
    listing = db.get(Listing, order.listing_id)
    if any(s.quantity > 0 for s in listing.sizes):
        text = f"«{listing.title}»: {size.label} өлшемі таусылды. Тағы болса, қалдықты жаңартыңыз."
        text_ru = f"«{listing.title}»: размер {size.label} закончился. Если есть ещё, обновите остаток."
        text_en = f"“{listing.title}”: size {size.label} is sold out. If you have more, update the stock."
    else:
        text = f"«{listing.title}» толық сатылды. Тағы болса, қалдықты жаңартып, қайта сатылымға қойыңыз."
        text_ru = f"«{listing.title}» распродан. Если есть ещё, обновите остаток и верните в продажу."
        text_en = f"“{listing.title}” is sold out. If you have more, update the stock and put it back on sale."
    notify(db, order.seller_id, "sold_out", text, text_ru, text_en, listing_id=listing.id)


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


def record_overpayment(db: Session, order: Order, event_id: str, amount: int) -> None:
    """A capture the order did not need: owed straight back to the buyer, outside the order's escrow."""
    post_tx(db, key=f"payment:{event_id}", order_id=order.id, kind="overpayment", actor="system",
            entries=[Entry(PROVIDER_CLEARING, debit=amount), Entry(buyer_refund(str(order.buyer_id)), credit=amount)])


def record_refund_paid(db: Session, order: Order, event_id: str, amount: int) -> None:
    """The provider sent the refund: the platform no longer owes the buyer that money."""
    post_tx(db, key=f"refund:{event_id}", order_id=order.id, kind="refund_paid", actor="system",
            entries=[Entry(buyer_refund(str(order.buyer_id)), debit=amount), Entry(PROVIDER_CLEARING, credit=amount)])


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
    # One atomic increment: a read-modify-write here could overwrite an order placed at the same moment.
    db.execute(update(ListingSize).where(ListingSize.id == order.size_id)
               .values(quantity=ListingSize.quantity + 1).execution_options(synchronize_session=False))
    size = db.get(ListingSize, order.size_id)
    db.refresh(size, ["quantity"])
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
                   f"«{listing.title}», размер {label} снова в продаже.",
                   f"“{listing.title}”, size {label} is back on sale.", listing_id=listing.id)
            db.delete(alert)


def audit(db: Session, user_id: int | None, action: str, target: str, reason: str | None = None) -> None:
    db.add(AuditLog(actor_user_id=user_id, action=action, target=target, reason=reason))


def run_auto_complete(db: Session, *, now: datetime, window, rule: CommissionRule) -> list[int]:
    """Scheduler job: complete delivered orders whose confirmation window passed with no dispute."""
    done = []
    ids = db.scalars(select(Order.id).where(Order.status == OrderStatus.DELIVERED_PENDING_CONFIRMATION.value)
                     .order_by(Order.id)).all()
    db.rollback()
    for order_id in ids:
        try:
            order = locked_order(db, order_id)
            if (order is None or order.status != OrderStatus.DELIVERED_PENDING_CONFIRMATION.value
                    or now < aware(order.delivered_at) + window):
                db.rollback()
                continue
            move(db, order, OrderStatus.COMPLETED, Actor.SCHEDULER, now=now, confirm_after=window)
            settle(db, order, refund_tiyn=0, rule=rule, actor="scheduler")
            db.commit()
            done.append(order.id)
        except Exception:
            db.rollback()
            log.exception("auto-completing order %s failed", order_id)
    return done


REVIEW_REMINDER_AFTER = timedelta(days=3)
# Orders completed longer ago than this are left alone: a reminder about a months-old pair reads as spam.
REVIEW_REMINDER_UNTIL = timedelta(days=30)


def run_review_reminders(db: Session, *, now: datetime, after=REVIEW_REMINDER_AFTER) -> list[int]:
    """Scheduler job: a few days after an order completes with no review, the buyer gets one reminder.
    Reviews are what new buyers trust a shop by, and most happy buyers simply forget."""
    completed = (select(OrderEvent.order_id, func.max(OrderEvent.at).label("at"))
                 .where(OrderEvent.to_status == OrderStatus.COMPLETED.value).group_by(OrderEvent.order_id).subquery())
    rows = db.execute(select(Order, completed.c.at).join(completed, completed.c.order_id == Order.id)
                      .outerjoin(Review, Review.order_id == Order.id)
                      .where(Order.status == OrderStatus.COMPLETED.value, Order.review_reminded_at.is_(None),
                             Review.id.is_(None))).all()
    done = []
    for order, at in rows:
        age = now - aware(at)
        if age < after or age > REVIEW_REMINDER_UNTIL:
            continue
        listing = db.get(Listing, order.listing_id)
        title = order.listing_title or (listing.title if listing else f"№{order.id}")
        notify(db, order.buyer_id, "review_reminder",
               f"«{title}» қалай болды? Пікіріңіз басқа сатып алушыларға таңдауға көмектеседі.",
               f"Как вам «{title}»? Ваш отзыв поможет другим покупателям с выбором.",
               f"How is “{title}”? Your review helps other buyers choose.", order_id=order.id)
        order.review_reminded_at = now
        done.append(order.id)
    db.commit()
    return done


STALE_AFTER = timedelta(days=21)
STALE_FEW_VIEWS = 30  # below this the listing is not being seen; above it, seen but not chosen


def run_stale_listing_tips(db: Session, *, now: datetime, after=STALE_AFTER) -> list[int]:
    """Scheduler job: once per listing, three weeks on sale with no order, the seller gets one concrete tip.
    Few views means people do not find it (photos, 360°, title); many views and no order usually means price."""
    started = func.coalesce(Listing.announced_at, Listing.created_at)
    ordered = select(Order.listing_id).where(Order.status != OrderStatus.CANCELLED.value)
    rows = db.scalars(select(Listing).where(Listing.status == "published", Listing.stale_nudged_at.is_(None),
                                            started <= now - after, Listing.id.not_in(ordered))).all()
    done = []
    for listing in rows:
        t = listing.title
        if listing.views >= STALE_FEW_VIEWS:
            kk = (f"«{t}» {listing.views} рет қаралды, бірақ әлі сатылмады. Бағаны 5–10% түсіріп көріңіз: "
                  f"таңдаулыға қосқандарға хабар барады.")
            ru = (f"«{t}» посмотрели {listing.views} раз, но не купили. Попробуйте снизить цену на 5–10%: "
                  f"добавившие в избранное получат уведомление.")
            en = (f"“{t}” was viewed {listing.views} times but has not sold. Try 5–10% off: "
                  f"people who saved it will be told.")
        elif not any(m.angle == "frame" for m in listing.media):
            kk = f"«{t}» 3 аптада аз қаралды. 360° көрініс қосыңыз: ондай тауарларды жиі ашады."
            ru = f"«{t}» мало смотрели за 3 недели. Добавьте обзор 360°: такие товары открывают чаще."
            en = f"“{t}” got few views in 3 weeks. Add a 360° view: listings with one get opened more."
        else:
            kk = f"«{t}» 3 аптада аз қаралды. Атауына бренд пен модельді жазып, бірінші фотоны жарығырақ етіңіз."
            ru = f"«{t}» мало смотрели за 3 недели. Укажите бренд и модель в названии и сделайте первое фото светлее."
            en = f"“{t}” got few views in 3 weeks. Put brand and model in the title and use a brighter first photo."
        notify(db, listing.seller_id, "listing_tip", kk, ru, en, listing_id=listing.id)
        listing.stale_nudged_at = now
        done.append(listing.id)
    db.commit()
    return done


# How long an order may hold a pair without money behind it. Payment pages of providers expire well within
# the second limit; a payment that still arrives later is refunded by the payment webhook.
UNPAID_CREATED_TTL = timedelta(minutes=30)
UNPAID_PENDING_TTL = timedelta(hours=2)
# A paid order the seller neither accepted nor declined goes back to the buyer as a full refund.
SELLER_ANSWER_TTL = timedelta(hours=48)
# An accepted order that never ships is refunded too: escrow is never held without a clock running.
SHIP_BY_TTL = timedelta(days=5)
# A parcel with no delivery news after this long, and a return the seller leaves unanswered, go to support.
DELIVERY_TTL = timedelta(days=21)
RETURN_ANSWER_TTL = timedelta(hours=48)


def entered_at(db: Session, order: Order) -> datetime:
    """When the order reached its current status."""
    at = db.scalar(select(func.max(OrderEvent.at)).where(OrderEvent.order_id == order.id,
                                                         OrderEvent.to_status == order.status))
    return aware(at or order.created_at)


EXPIRY = {OrderStatus.CREATED.value: UNPAID_CREATED_TTL, OrderStatus.PAYMENT_PENDING.value: UNPAID_PENDING_TTL,
          OrderStatus.PAID.value: SELLER_ANSWER_TTL, OrderStatus.SELLER_ACCEPTED.value: SHIP_BY_TTL,
          OrderStatus.PREPARING.value: SHIP_BY_TTL, OrderStatus.SHIPPED.value: DELIVERY_TTL,
          OrderStatus.IN_TRANSIT.value: DELIVERY_TTL, OrderStatus.RETURN_REQUESTED.value: RETURN_ANSWER_TTL}
# What the expiry job does when each clock runs out, and the reason it writes in the history.
REFUND_ON_EXPIRY = {OrderStatus.PAID.value: "seller did not answer",
                    OrderStatus.SELLER_ACCEPTED.value: "seller did not ship in time",
                    OrderStatus.PREPARING.value: "seller did not ship in time"}
DISPUTE_ON_EXPIRY = {OrderStatus.SHIPPED.value: "no delivery news in time",
                     OrderStatus.IN_TRANSIT.value: "no delivery news in time",
                     OrderStatus.RETURN_REQUESTED.value: "seller did not answer the return"}


def deadline(db: Session, order: Order, confirm_window: timedelta | None = None) -> datetime | None:
    """When a timer acts on this order if nobody does first; None when no clock is running.
    The inspection window after delivery is a setting, so it counts only when the caller passes it."""
    if order.status == OrderStatus.DELIVERED_PENDING_CONFIRMATION.value:
        return aware(order.delivered_at) + confirm_window if confirm_window and order.delivered_at else None
    ttl = EXPIRY.get(order.status)
    return entered_at(db, order) + ttl if ttl else None


def locked_order(db: Session, order_id: int) -> Order | None:
    """The order row, locked until commit, and re-read so a status another request just wrote is the one we see.
    Every status change starts here, so a job, a webhook and a tap at the same moment cannot both act."""
    return db.scalar(select(Order).where(Order.id == order_id).with_for_update().execution_options(
        populate_existing=True))


def run_purge(db: Session, *, now: datetime) -> list[str]:
    """Scheduler job: drop rows that only ever mattered for a short while, so these tables do not grow forever.
    Sign-in codes after two days (the daily failure cap reads one), dead tokens a week after expiry, webhook
    ids after half a year (providers retry for days, not months)."""
    from .models import AuthToken, OtpCode, WebhookEvent
    done = []
    for model, old in ((OtpCode, OtpCode.created_at < now - timedelta(days=2)),
                       (AuthToken, AuthToken.expires_at < now - timedelta(days=7)),
                       (WebhookEvent, WebhookEvent.received_at < now - timedelta(days=180))):
        n = db.execute(delete(model).where(old)).rowcount
        if n:
            done.append(f"{model.__tablename__}:{n}")
    db.commit()
    return done


def run_expire_orders(db: Session, *, now: datetime) -> dict[str, list[int]]:
    """Scheduler job: release pairs held by orders nobody paid for, refund paid orders the seller ignored or never
    shipped, and hand stalled deliveries and unanswered returns to support. One order per transaction, so one
    failure neither undoes the rest nor blocks the next pass."""
    cancelled, refunded, disputed = [], [], []
    ids = db.scalars(select(Order.id).where(Order.status.in_(EXPIRY)).order_by(Order.id)).all()
    db.rollback()
    for order_id in ids:
        try:
            order = locked_order(db, order_id)
            if order is None or order.status not in EXPIRY or now < deadline(db, order):
                db.rollback()
                continue
            status = order.status
            if status in REFUND_ON_EXPIRY:
                move(db, order, OrderStatus.REFUND_PENDING, Actor.SCHEDULER, now=now, reason=REFUND_ON_EXPIRY[status])
                order.pending_refund_tiyn = total_tiyn(order)
                restock(db, order)
                refunded.append(order.id)
            elif status in DISPUTE_ON_EXPIRY:
                move(db, order, OrderStatus.DISPUTED, Actor.SCHEDULER, now=now, reason=DISPUTE_ON_EXPIRY[status])
                order.dispute_reason = order.dispute_reason or DISPUTE_ON_EXPIRY[status]
                disputed.append(order.id)
            else:
                move(db, order, OrderStatus.CANCELLED, Actor.SCHEDULER, now=now, reason="not paid in time")
                restock(db, order)
                cancelled.append(order.id)
            db.commit()
        except Exception:
            db.rollback()
            log.exception("expiring order %s failed", order_id)
    return {"cancelled": cancelled, "refunded": refunded, "disputed": disputed}
