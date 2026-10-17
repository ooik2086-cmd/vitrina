"""The staff console: moderation, disputes, reports, evidence and the audit log."""
from __future__ import annotations

from fastapi import Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.orders import Actor, OrderStatus as S

from . import services
from .config import Settings
from .deps import get_db, get_settings, staff_user
from .errors import ApiError
from .models import AuditLog, ListingReport, Listing, Order, OrderEvent, User
from .api_common import api
from .schemas import ReasonIn, ReportCloseIn, ResolveIn
from .serializers import listing_out, moderation_out, order_out, order_summary, ordered_photos
from .saved_search_routes import announce
from .listing_routes import split_codes
from .order_routes import order_for


@api.post("/admin/orders/{order_id}/resolve")
def resolve_dispute(order_id: int, body: ResolveIn, staff: User = Depends(staff_user),
                    db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, staff, lock=True)
    # Only a dispute: on an order that never shipped a partial refund would pay the seller for nothing sent.
    if order.status != S.DISPUTED.value:
        raise ApiError(409, "invalid_status")
    if body.refund_tiyn > services.total_tiyn(order):
        raise ApiError(422, "validation", "refund exceeds the order total")
    if body.refund_tiyn == 0:
        services.move(db, order, S.COMPLETED, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
        services.settle(db, order, refund_tiyn=0, rule=cfg.commission, actor=f"support:{staff.id}", reason=body.reason)
    else:
        services.move(db, order, S.REFUND_PENDING, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
        order.pending_refund_tiyn = body.refund_tiyn
    services.audit(db, staff.id, "resolve_dispute", f"order:{order.id}", f"refund={body.refund_tiyn}; {body.reason}")
    db.commit()
    return order_out(order)


@api.post("/admin/orders/{order_id}/delivered")
def mark_delivered(order_id: int, body: ReasonIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Support confirms a delivery the courier never reported (a call, a photo of the handover)."""
    order = order_for(db, order_id, staff, lock=True)
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    services.move(db, order, S.DELIVERED_PENDING_CONFIRMATION, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
    services.audit(db, staff.id, "mark_delivered", f"order:{order.id}", body.reason)
    db.commit()
    return order_out(order)


@api.post("/admin/listings/{listing_id}/unhide")
def unhide_listing(listing_id: int, body: ReasonIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Undo a hide: the listing goes back to the seller as a draft, and publishing runs moderation again."""
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    if listing.status != "hidden":
        raise ApiError(409, "invalid_status")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    listing.status = "draft"
    services.audit(db, staff.id, "unhide_listing", f"listing:{listing.id}", body.reason)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.post("/admin/listings/{listing_id}/hide")
def hide_listing(listing_id: int, body: ReasonIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    listing.status = "hidden"
    services.audit(db, staff.id, "hide_listing", f"listing:{listing.id}", body.reason)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.get("/admin/overview")
def admin_overview(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    orders = dict(db.execute(select(Order.status, func.count(Order.id)).group_by(Order.status)).all())
    listings = dict(db.execute(select(Listing.status, func.count(Listing.id)).group_by(Listing.status)).all())
    gmv = db.scalar(select(func.coalesce(func.sum(Order.item_price_tiyn), 0)).where(Order.status == S.COMPLETED.value))
    from .authenticity import SELLER_EVIDENCE
    from .models import Payout
    count = lambda stmt: db.scalar(select(func.count()).select_from(stmt.subquery()))  # noqa: E731
    queues = {  # what waits on support, shown as numbers on the console's tabs
        "moderation": listings.get("moderation", 0),
        "authenticity": count(select(Listing.id).where(
            Listing.authenticity == SELLER_EVIDENCE,
            Listing.status.in_(("published", "paused", "sold", "moderation")))),
        "disputes": orders.get(S.DISPUTED.value, 0),
        "reports": count(select(ListingReport.listing_id).where(ListingReport.status == "open").distinct()),
        "payouts": count(select(Payout.id).where(Payout.status == "requested")),
    }
    return {"orders": orders, "listings": listings, "completed_item_value_tiyn": int(gmv or 0), "queues": queues,
            "users": db.scalar(select(func.count(User.id))), "sellers": db.scalar(
                select(func.count(User.id)).where(User.is_seller.is_(True)))}


@api.get("/admin/orders")
def admin_orders(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Order).order_by(Order.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Order.status == status)
    items = []
    for o in db.scalars(stmt).all():
        events = db.scalars(select(OrderEvent).where(OrderEvent.order_id == o.id).order_by(OrderEvent.id)).all()
        items.append({**order_summary(db, o), "history": [
            {"status": e.to_status, "actor": e.actor, "reason": e.reason, "at": services.aware(e.at).isoformat()}
            for e in events]})
    return {"items": items}


@api.get("/admin/listings")
def admin_listings(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Listing).order_by(Listing.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Listing.status == status)
    return {"items": [listing_out(db, r) for r in db.scalars(stmt).all()]}


@api.get("/admin/moderation")
def admin_moderation(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Listings the publish checks flagged, oldest first so nobody waits longest."""
    rows = db.scalars(select(Listing).where(Listing.status == "moderation").order_by(Listing.id)).all()
    return {"items": [{"listing": listing_out(db, r), "moderation": moderation_out(r)} for r in rows]}


class ModerationRejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=2000)


def queued_listing(db: Session, listing_id: int) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    if listing.status != "moderation":
        raise ApiError(409, "invalid_status")
    return listing


@api.post("/admin/moderation/{listing_id}/approve")
def approve_listing(listing_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    listing = queued_listing(db, listing_id)
    listing.status = "published"
    # Remember what was cleared so pausing and republishing does not queue the same listing again.
    listing.moderation_cleared = ",".join(sorted(set(split_codes(listing.moderation_cleared))
                                                 | set(split_codes(listing.moderation_flags)))) or None
    listing.moderation_note = None
    announce(db, listing)
    services.audit(db, staff.id, "approve_listing", f"listing:{listing.id}", listing.moderation_flags or "")
    services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» тексеруден өтті және сатылымда.",
                    f"«{listing.title}» прошёл проверку и уже продаётся.",
                    f"“{listing.title}” passed review and is on sale.", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.post("/admin/moderation/{listing_id}/reject")
def reject_listing(listing_id: int, body: ModerationRejectIn, staff: User = Depends(staff_user),
                   db: Session = Depends(get_db)):
    listing = queued_listing(db, listing_id)
    reason = body.reason.strip()
    listing.status, listing.moderation_note = "rejected", reason
    services.audit(db, staff.id, "reject_listing", f"listing:{listing.id}", reason)
    services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» қайтарылды: {reason}",
                    f"«{listing.title}» возвращён: {reason}",
                    f"“{listing.title}” was sent back: {reason}", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@api.get("/admin/reports")
def admin_reports(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Open reports grouped by listing, most-reported first."""
    rows = db.scalars(select(ListingReport).where(ListingReport.status == "open").order_by(ListingReport.id)).all()
    by_listing: dict[int, list[ListingReport]] = {}
    for r in rows:
        by_listing.setdefault(r.listing_id, []).append(r)
    items = [{"listing": listing_out(db, db.get(Listing, lid)),
              "reports": [{"id": r.id, "reason": r.reason, "text": r.text, "reporter_id": r.reporter_id,
                           "at": services.aware(r.created_at).isoformat()} for r in reports]}
             for lid, reports in by_listing.items()]
    items.sort(key=lambda i: -len(i["reports"]))
    return {"items": items}


@api.post("/admin/reports/{listing_id}/close")
def close_reports(listing_id: int, body: ReportCloseIn, staff: User = Depends(staff_user),
                  db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    reports = db.scalars(select(ListingReport).where(ListingReport.listing_id == listing_id,
                                                     ListingReport.status == "open")).all()
    if listing is None or not reports:
        raise ApiError(404, "not_found")
    outcome = "hidden" if body.action == "hide" else "dismissed"
    for r in reports:
        r.status = outcome
    if body.action == "hide":
        listing.status = "hidden"
        services.notify(db, listing.seller_id, "listing_hidden",
                        f"«{listing.title}» модератор шешімімен жасырылды: {body.reason}",
                        f"«{listing.title}» скрыт по решению модератора: {body.reason}",
                        f"“{listing.title}” was hidden by a moderator: {body.reason}")
    for reporter in {r.reporter_id for r in reports}:
        services.notify(db, reporter, "report_closed",
                        f"«{listing.title}» туралы шағымыңыз қаралды: "
                        + ("тауар жасырылды." if body.action == "hide" else "бұзушылық табылмады."),
                        f"Ваша жалоба на «{listing.title}» рассмотрена: "
                        + ("товар скрыт." if body.action == "hide" else "нарушений не найдено."),
                        f"Your report on “{listing.title}” was reviewed: "
                        + ("the listing was hidden." if body.action == "hide" else "no violation found."))
    services.audit(db, staff.id, f"reports_{outcome}", f"listing:{listing.id}", body.reason)
    db.commit()
    return {"listing_id": listing.id, "status": listing.status, "closed": len(reports)}


@api.get("/admin/audit")
def admin_audit(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(AuditLog).order_by(AuditLog.id.desc()).limit(100)).all()
    return {"items": [{"actor_user_id": r.actor_user_id, "action": r.action, "target": r.target, "reason": r.reason,
                       "at": services.aware(r.at).isoformat()} for r in rows]}


@api.get("/admin/orders/{order_id}/evidence")
def order_evidence(order_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """What support decides a dispute on: both sides' words, the chat with its photos, and the parcel details.
    Read-only, and every look is written to the audit log because it shows a private conversation."""
    from .models import Conversation, Message
    order = order_for(db, order_id, staff)
    conv = db.scalar(select(Conversation).where(Conversation.listing_id == order.listing_id,
                                                Conversation.buyer_id == order.buyer_id))
    messages = [] if conv is None else db.scalars(select(Message).where(Message.conversation_id == conv.id)
                                                  .order_by(Message.id).limit(500)).all()
    events = db.scalars(select(OrderEvent).where(OrderEvent.order_id == order.id).order_by(OrderEvent.id)).all()
    services.audit(db, staff.id, "view_evidence", f"order:{order.id}")
    db.commit()
    return {"tracking_number": order.tracking_number, "dispute_reason": order.dispute_reason,
            "listing_title": order.listing_title, "listing_photos": ordered_photos(order),
            "delivery_city": order.delivery_city,
            "delivered_at": services.aware(order.delivered_at).isoformat() if order.delivered_at else None,
            "statements": [{"actor": e.actor, "status": e.to_status, "reason": e.reason,
                            "at": services.aware(e.at).isoformat()} for e in events if e.reason],
            "messages": [{"from": "buyer" if m.sender_id == order.buyer_id else "seller", "body": m.body,
                          "photo_url": m.photo_url, "at": services.aware(m.created_at).isoformat()} for m in messages]}


@api.get("/admin/orders/{order_id}/ledger")
def order_ledger(order_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    from .models import LedgerTx
    txs = db.scalars(select(LedgerTx).where(LedgerTx.order_id == order_id).order_by(LedgerTx.id)).all()
    return {"transactions": [{"kind": t.kind, "actor": t.actor, "reason": t.reason,
                              "entries": [{"account": e.account, "debit": e.debit, "credit": e.credit} for e in t.entries]}
                             for t in txs]}
