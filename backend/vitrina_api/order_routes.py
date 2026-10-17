"""Orders: from checkout to delivery, return and review, each step checked by the order state machine."""
from __future__ import annotations

import json
import re
from typing import Literal

from fastapi import Depends, Header
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.orders import Actor, OrderStatus as S

from . import services
from . import coupons, offers
from .config import Settings
from .deps import current_user, get_db, get_settings
from .errors import ApiError
from .models import IdempotencyRecord, Listing, ListingSize, Order, OrderEvent, Review, User
from .api_common import DECLINABLE, IN_DELIVERY, PHONE_RE, api
from .schemas import DeliveryIn, OrderIn, ReasonIn, ShipIn
from .serializers import away_until, delivery_out, listing_cover, order_out, order_summary


def order_for(db: Session, order_id: int, user: User, *, role: str | None = None, lock: bool = False) -> Order:
    """Returns 404 (not 403) for orders the user is not part of, so ids leak nothing.
    With lock, the row stays locked until commit: every action that changes an order's status takes it."""
    order = services.locked_order(db, order_id) if lock else db.get(Order, order_id)
    if order is None:
        raise ApiError(404, "not_found")
    is_party = user.id in (order.buyer_id, order.seller_id)
    if role == "buyer" and user.id != order.buyer_id or role == "seller" and user.id != order.seller_id:
        raise ApiError(404, "not_found")
    if role is None and not is_party and user.role not in ("support", "admin"):
        raise ApiError(404, "not_found")
    return order


def clean_delivery(body: DeliveryIn) -> dict:
    phone = re.sub(r"[\s()\-]", "", body.recipient_phone)
    if phone.startswith("8") and len(phone) == 11:
        phone = "+7" + phone[1:]
    if not PHONE_RE.match(phone):
        raise ApiError(422, "invalid_phone")
    values = {"recipient_name": body.recipient_name.strip(), "recipient_phone": phone, "city": body.city.strip(),
              "address": body.address.strip(), "note": (body.note or "").strip() or None}
    if len(values["recipient_name"]) < 2 or len(values["city"]) < 2 or len(values["address"]) < 5:
        raise ApiError(422, "validation", "delivery fields are required")
    return values


@api.post("/orders", status_code=201)
def create_order(body: OrderIn, user: User = Depends(current_user), db: Session = Depends(get_db),
                 cfg: Settings = Depends(get_settings), idempotency_key: str | None = Header(default=None)):
    if not idempotency_key:
        raise ApiError(400, "idempotency_key_required")
    seen = db.scalar(select(IdempotencyRecord).where(IdempotencyRecord.user_id == user.id,
                                                     IdempotencyRecord.scope == "create_order",
                                                     IdempotencyRecord.key == idempotency_key))
    if seen:
        return order_out(db.get(Order, seen.order_id))
    listing = db.get(Listing, body.listing_id)
    if listing is None or listing.status != "published":
        raise ApiError(404, "not_found")
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    if away_until(db.get(User, listing.seller_id)):
        raise ApiError(409, "seller_away")
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    delivery = clean_delivery(body.delivery)
    offer = offers.offer_for_order(db, body.offer_id, user, listing, body.size_id) if body.offer_id else None
    size = db.scalar(select(ListingSize).where(ListingSize.id == body.size_id,
                                               ListingSize.listing_id == listing.id).with_for_update())
    if size is None or size.quantity <= 0:
        raise ApiError(409, "out_of_stock")
    # The listing may have got cheaper than the offer since; the buyer always pays the lower.
    price = min(listing.price_tiyn, offers.price(offer)) if offer else listing.price_tiyn
    promo, off = None, 0
    if body.promo_code:
        if offer:
            raise ApiError(409, "promo_with_offer")
        promo, off = coupons.apply(db, body.promo_code, listing, price, user, lock=True)
    size.quantity -= 1
    if not any(s.quantity > 0 for s in listing.sizes):
        listing.status = "sold"
    order = Order(buyer_id=user.id, seller_id=listing.seller_id, listing_id=listing.id, size_id=size.id,
                  status=S.CREATED.value, item_price_tiyn=price - off,
                  promo_code_id=promo.id if promo else None, promo_code=promo.code if promo else None,
                  promo_discount_tiyn=off,
                  delivery_price_tiyn=listing.delivery_price_tiyn, commission_version=cfg.commission.version,
                  recipient_name=delivery["recipient_name"], recipient_phone=delivery["recipient_phone"],
                  delivery_city=delivery["city"], delivery_address=delivery["address"],
                  delivery_note=delivery["note"], listing_title=listing.title, listing_cover=listing_cover(listing))
    user.last_delivery = json.dumps(delivery, ensure_ascii=False)
    db.add(order)
    db.flush()
    if offer:
        offer.status, offer.order_id = "ordered", order.id
    db.add(IdempotencyRecord(user_id=user.id, scope="create_order", key=idempotency_key, order_id=order.id))
    try:
        db.commit()
    except IntegrityError:
        # The same tap arrived twice at once and the other request won: answer with its order, take nothing.
        db.rollback()
        seen = db.scalar(select(IdempotencyRecord).where(IdempotencyRecord.user_id == user.id,
                                                         IdempotencyRecord.scope == "create_order",
                                                         IdempotencyRecord.key == idempotency_key))
        if seen is None:
            raise
        return order_out(db.get(Order, seen.order_id))
    return order_out(order)


@api.get("/orders")
def list_orders(role: Literal["buyer", "seller"] = "buyer", user: User = Depends(current_user),
                db: Session = Depends(get_db)):
    column = Order.buyer_id if role == "buyer" else Order.seller_id
    rows = db.scalars(select(Order).where(column == user.id).order_by(Order.id.desc()).limit(100)).all()
    return {"items": [order_summary(db, o) for o in rows]}


@api.get("/orders/{order_id}")
def get_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
              cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, user)
    reviewed = db.scalar(select(Review.id).where(Review.order_id == order.id)) is not None
    events = db.scalars(select(OrderEvent).where(OrderEvent.order_id == order.id).order_by(OrderEvent.id)).all()
    act_by = services.deadline(db, order, cfg.confirm_window)
    return {**order_summary(db, order), "reviewed": reviewed, "delivery": delivery_out(order, user),
            "deadline": act_by.isoformat() if act_by else None,
            "history": [{"status": e.to_status, "at": services.aware(e.at).isoformat()} for e in events]}


@api.post("/orders/{order_id}/pay")
def start_payment(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer", lock=True)
    if order.status == S.CREATED.value:
        services.move(db, order, S.PAYMENT_PENDING, Actor.BUYER, user_id=user.id)
        db.commit()
    elif order.status != S.PAYMENT_PENDING.value:
        raise ApiError(409, "invalid_status")
    # Sandbox only: a real provider returns its own payment form/session here.
    return {"provider": "sandbox", "order_id": order.id, "amount_tiyn": services.total_tiyn(order), "currency": "KZT"}


@api.post("/orders/{order_id}/cancel")
def cancel_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer", lock=True)
    if order.status in (S.CREATED.value, S.PAYMENT_PENDING.value):
        services.move(db, order, S.CANCELLED, Actor.BUYER, user_id=user.id)
    else:  # once paid, cancelling means a full refund through the provider
        services.move(db, order, S.REFUND_PENDING, Actor.BUYER, user_id=user.id, reason="buyer cancelled")
        order.pending_refund_tiyn = services.total_tiyn(order)
    services.restock(db, order)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/decline")
def decline_order(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller", lock=True)
    # Only before the pair leaves: a "decline" on a return would refund in full and put back a shoe still away.
    if order.status not in DECLINABLE:
        raise ApiError(409, "invalid_status")
    services.move(db, order, S.REFUND_PENDING, Actor.SELLER, user_id=user.id, reason=body.reason)
    order.pending_refund_tiyn = services.total_tiyn(order)
    services.restock(db, order)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/accept")
def accept_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller", lock=True)
    services.move(db, order, S.SELLER_ACCEPTED, Actor.SELLER, user_id=user.id)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/ship")
def ship_order(order_id: int, body: ShipIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller", lock=True)
    # A number already on another parcel would let its delivery complete this order too.
    taken = db.scalar(select(Order.id).where(Order.tracking_number == body.tracking_number.strip(),
                                             Order.id != order.id, Order.status.in_(IN_DELIVERY)))
    if taken is not None:
        raise ApiError(409, "tracking_in_use")
    services.move(db, order, S.SHIPPED, Actor.SELLER, user_id=user.id, tracking_number=body.tracking_number)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/confirm")
def confirm_order(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db),
                  cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, user, role="buyer", lock=True)
    services.move(db, order, S.COMPLETED, Actor.BUYER, user_id=user.id)
    services.settle(db, order, refund_tiyn=0, rule=cfg.commission, actor=f"buyer:{user.id}")
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/received")
def mark_received(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The buyer has the parcel though no courier reported it: this starts the inspection window, it does not
    release the money."""
    order = order_for(db, order_id, user, role="buyer", lock=True)
    services.move(db, order, S.DELIVERED_PENDING_CONFIRMATION, Actor.BUYER, user_id=user.id, reason="buyer received")
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/dispute")
def open_dispute(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The buyer disputes a delivery or a return the seller ignores; the seller disputes only a return."""
    order = order_for(db, order_id, user, lock=True)
    if user.id not in (order.buyer_id, order.seller_id):
        raise ApiError(404, "not_found")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    actor = Actor.BUYER if user.id == order.buyer_id else Actor.SELLER
    services.move(db, order, S.DISPUTED, actor, user_id=user.id, reason=body.reason)
    order.dispute_reason = body.reason
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/return")
def request_return(order_id: int, body: ReasonIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="buyer", lock=True)
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    services.move(db, order, S.RETURN_REQUESTED, Actor.BUYER, user_id=user.id, reason=body.reason)
    db.commit()
    return order_out(order)


@api.post("/orders/{order_id}/approve-return")
def approve_return(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = order_for(db, order_id, user, role="seller", lock=True)
    services.move(db, order, S.REFUND_PENDING, Actor.SELLER, user_id=user.id, reason="seller approved return")
    order.pending_refund_tiyn = services.total_tiyn(order)
    db.commit()
    return order_out(order)
