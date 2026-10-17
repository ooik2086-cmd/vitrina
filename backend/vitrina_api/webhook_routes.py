"""Signed events from the payment and delivery providers."""
from __future__ import annotations

import json

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.orders import Actor, OrderStatus as S
from vitrina_core.webhooks import WebhookRejected, verify

from . import services
from .config import Settings
from .deps import get_db, get_settings
from .errors import ApiError
from .models import Order, WebhookEvent
from .api_common import IN_DELIVERY


async def raw_body(request: Request) -> bytes:
    """Read in the event loop, so the handler itself can be a plain function that runs in the threadpool:
    database work inside an async handler would stall every other request."""
    return await request.body()


def verified_event(request: Request, body: bytes, secret: bytes) -> dict:
    try:
        ts = int(request.headers.get("X-Timestamp", "0"))
        verify(secret, ts, body, request.headers.get("X-Signature", ""))
        return json.loads(body)
    except (WebhookRejected, ValueError) as exc:
        raise ApiError(401, "bad_signature", str(exc)) from exc


def first_time(db: Session, source: str, event_id: str) -> bool:
    db.add(WebhookEvent(source=source, event_id=event_id))
    try:
        db.flush()
        return True
    except IntegrityError:
        db.rollback()
        return False


hooks = APIRouter(prefix="/api/v1/webhooks")


@hooks.post("/payments/sandbox")
def payment_webhook(request: Request, body: bytes = Depends(raw_body), db: Session = Depends(get_db),
                    cfg: Settings = Depends(get_settings)):
    event = verified_event(request, body, cfg.payment_webhook_secret)
    try:
        event_id, kind, order_id = str(event["id"]), event["type"], int(event["order_id"])
        amount, currency = event["amount_tiyn"], event["currency"]
    except (KeyError, TypeError, ValueError) as exc:
        raise ApiError(422, "validation", f"malformed event: {exc}") from exc
    if not first_time(db, "payments", event_id):
        return {"result": "duplicate"}
    order = services.locked_order(db, order_id)
    if order is None:
        db.rollback()
        raise ApiError(404, "not_found")
    if kind == "payment.succeeded":
        if amount != services.total_tiyn(order) or currency != "KZT":
            db.rollback()
            raise ApiError(409, "amount_mismatch")
        if order.status == S.CANCELLED.value:
            # Paid after the order was cancelled (by the buyer, or because it waited too long): the money is in,
            # so it is held and refunded in full. The pair was already put back on sale at the cancel.
            services.record_payment(db, order, event_id)
            services.move(db, order, S.REFUND_PENDING, Actor.SYSTEM, reason="paid after cancel")
            order.pending_refund_tiyn = services.total_tiyn(order)
            db.commit()
            return {"result": "refund", "status": order.status}
        if order.status != S.PAYMENT_PENDING.value:
            # A second capture for an order that is already paid (two tabs, a retried session) or being refunded.
            # The money is real: it is booked as owed to the buyer and support refunds it, never dropped.
            services.record_overpayment(db, order, event_id, amount)
            services.audit(db, None, "overpayment", f"order:{order.id}", f"event={event_id}; amount={amount}")
            db.commit()
            return {"result": "overpayment", "status": order.status}
        services.record_payment(db, order, event_id)
        services.move(db, order, S.PAID, Actor.SYSTEM)
        services.notify_sold_out(db, order)
    elif kind == "refund.succeeded":
        if order.status != S.REFUND_PENDING.value or amount != order.pending_refund_tiyn:
            db.rollback()
            raise ApiError(409, "amount_mismatch")
        services.move(db, order, S.REFUNDED, Actor.SYSTEM)
        services.settle(db, order, refund_tiyn=amount, rule=cfg.commission, actor="system")
        services.record_refund_paid(db, order, event_id, amount)
    db.commit()
    return {"result": "applied", "status": order.status}


@hooks.post("/delivery/sandbox")
def delivery_webhook(request: Request, body: bytes = Depends(raw_body), db: Session = Depends(get_db),
                     cfg: Settings = Depends(get_settings)):
    event = verified_event(request, body, cfg.delivery_webhook_secret)
    # Only an order still on its way: a number reused later, or one already delivered, is not this parcel.
    order_id = db.scalar(select(Order.id).where(Order.tracking_number == str(event.get("tracking_number", "")),
                                                Order.status.in_(IN_DELIVERY)).order_by(Order.id.desc()))
    if order_id is None:
        raise ApiError(404, "not_found")
    if not first_time(db, "delivery", str(event.get("id"))):
        return {"result": "duplicate"}
    order = services.locked_order(db, order_id)
    target = {"delivery.in_transit": S.IN_TRANSIT, "delivery.delivered": S.DELIVERED_PENDING_CONFIRMATION}.get(event.get("type"))
    if target is None:
        db.commit()
        return {"result": "ignored"}
    if order.status == target.value:
        db.commit()
        return {"result": "duplicate", "status": order.status}
    services.move(db, order, target, Actor.SYSTEM)
    db.commit()
    return {"result": "applied", "status": order.status}
