"""The staff console: moderation, disputes, reports, evidence and the audit log."""
from __future__ import annotations

import hashlib
import json
from collections import defaultdict

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from vitrina_core.orders import Actor, OrderStatus as S

from . import services
from .config import Settings
from .deps import get_db, get_private, get_settings, staff_user
from .errors import ApiError
from .models import AuditLog, AuthProof, ListingReport, Listing, Order, OrderEvent, OrderEvidence, User, utcnow
from .schemas import EvidenceRequestIn, ReasonIn, ReportCloseIn, ResolveIn
from .serializers import (LIGHT, listing_out, moderation_out, order_out, order_summary, ordered_details,
                          ordered_photos, preload_orders, preload_sellers, with_light_media)
from .saved_search_routes import announce
from .storage import Storage, private_link
from .listing_routes import back_from_hold, settle_stock_status, split_codes
from .order_routes import dispute_evidence_until, order_evidence_list, order_for


router = APIRouter(prefix="/api/v1")


@router.post("/admin/orders/{order_id}/resolve")
def resolve_dispute(order_id: int, body: ResolveIn, staff: User = Depends(staff_user),
                    db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    order = order_for(db, order_id, staff, lock=True)
    # Only a dispute: on an order that never shipped a partial refund would pay the seller for nothing sent.
    if order.status != S.DISPUTED.value:
        raise ApiError(409, "invalid_status")
    if not body.reason.strip():
        raise ApiError(422, "reason_required")  # both sides are told why, and the audit log keeps it
    until = dispute_evidence_until(db, order)
    sides = set(db.scalars(select(OrderEvidence.user_id).where(OrderEvidence.order_id == order.id)).all())
    both_shown = {order.buyer_id, order.seller_id} <= sides
    if until and utcnow() < until and not both_shown and not body.early:
        raise ApiError(409, "evidence_window_open", until.isoformat())
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


@router.post("/admin/orders/{order_id}/request-evidence")
def request_evidence(order_id: int, body: EvidenceRequestIn, staff: User = Depends(staff_user),
                     db: Session = Depends(get_db)):
    """Support asks one side for something the case still lacks (the label, the sole, the parcel)."""
    order = order_for(db, order_id, staff)
    if order.status != S.DISPUTED.value:
        raise ApiError(409, "invalid_status")
    note = body.note.strip()
    short = note if len(note) <= 200 else note[:199] + "…"  # a notice holds 300 characters; the log keeps it all
    who = order.buyer_id if body.side == "buyer" else order.seller_id
    services.notify(db, who, "evidence_request", f"Тапсырыс №{order.id}: қолдау қызметі дәлел сұрайды. {short}",
                    f"Заказ №{order.id}: поддержка просит доказательство. {short}",
                    f"Order No. {order.id}: support asks for evidence. {short}", order_id=order.id)
    services.audit(db, staff.id, "request_evidence", f"order:{order.id}", f"{body.side}: {note}")
    db.commit()
    return {"ok": True}


@router.post("/admin/orders/{order_id}/delivered")
def mark_delivered(order_id: int, body: ReasonIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Support confirms a delivery the courier never reported (a call, a photo of the handover)."""
    order = order_for(db, order_id, staff, lock=True)
    if not body.reason.strip():
        raise ApiError(422, "reason_required")
    services.move(db, order, S.DELIVERED_PENDING_CONFIRMATION, Actor.SUPPORT, user_id=staff.id, reason=body.reason)
    services.audit(db, staff.id, "mark_delivered", f"order:{order.id}", body.reason)
    db.commit()
    return order_out(order)


@router.post("/admin/listings/{listing_id}/unhide")
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


@router.post("/admin/listings/{listing_id}/hide")
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


@router.get("/admin/overview")
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


@router.get("/admin/orders")
def admin_orders(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Order).order_by(Order.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Order.status == status)
    items = []
    rows = db.scalars(stmt).all()
    # Support sees which disputes have new evidence without opening each one.
    evidence = {oid: (n, at) for oid, n, at in db.execute(
        select(OrderEvidence.order_id, func.count(OrderEvidence.id), func.max(OrderEvidence.created_at))
        .where(OrderEvidence.order_id.in_([o.id for o in rows])).group_by(OrderEvidence.order_id)).all()}
    preload_orders(db, rows)
    history = defaultdict(list)
    for e in db.scalars(select(OrderEvent).where(OrderEvent.order_id.in_([o.id for o in rows]))
                        .order_by(OrderEvent.id)):
        history[e.order_id].append(e)
    for o in rows:
        events = history[o.id]
        n, last = evidence.get(o.id, (0, None))
        items.append({**order_summary(db, o), "evidence_count": n,
                      "last_evidence_at": services.aware(last).isoformat() if last else None, "history": [
            {"status": e.to_status, "actor": e.actor, "reason": e.reason, "at": services.aware(e.at).isoformat()}
            for e in events]})
    return {"items": items}


@router.get("/admin/listings")
def admin_listings(status: str | None = None, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    stmt = select(Listing).order_by(Listing.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Listing.status == status)
    return {"items": [listing_out(db, r) for r in db.scalars(stmt).all()]}


@router.get("/admin/moderation")
def admin_moderation(staff: User = Depends(staff_user), db: Session = Depends(get_db),
                     cfg: Settings = Depends(get_settings)):
    """Listings the publish checks flagged, oldest first so nobody waits longest."""
    rows = db.scalars(select(Listing).where(Listing.status == "moderation").order_by(Listing.id)).all()
    items = []
    for r in rows:
        back_to, back_missing = back_from_hold(cfg, r)
        # back_to: where Approve puts it, so staff know a pair its seller paused is not put on sale by approving it;
        # back_missing: what a publish still asks of its seller then. seen goes back with Approve (see approve_listing).
        items.append({"listing": listing_out(db, r), "moderation": moderation_out(r), "back_to": back_to,
                      "back_missing": back_missing, "seen": review_seen(r)})
    return {"items": items}


def review_seen(listing: Listing) -> str:
    """A short fingerprint of what staff judge on the queue page: the words, condition, price, photos and flags."""
    shown = [listing.title, listing.brand, listing.model_name, listing.description, listing.defects, listing.condition,
             listing.price_tiyn, listing.moderation_flags,
             sorted((m.id, m.angle, m.original_url) for m in listing.media)]
    return hashlib.sha256(json.dumps(shown, default=str).encode()).hexdigest()[:16]


class ModerationApproveIn(BaseModel):
    seen: str | None = Field(default=None, max_length=64)  # review_seen of the version staff looked at


class ModerationRejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=2000)


def queued_listing(db: Session, listing_id: int) -> Listing:
    # Locked (on Postgres) as the seller's edit locks it, so a Save that ends the check and a staff decision never
    # both take the listing out of the queue.
    listing = db.get(Listing, listing_id, with_for_update=True, populate_existing=True)
    if listing is None:
        raise ApiError(404, "not_found")
    if listing.status != "moderation":
        raise ApiError(409, "invalid_status")
    return listing


@router.post("/admin/moderation/{listing_id}/approve")
def approve_listing(listing_id: int, body: ModerationApproveIn | None = None, staff: User = Depends(staff_user),
                    db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    listing = queued_listing(db, listing_id)
    if body and body.seen and body.seen != review_seen(listing):
        # The seller saved a change after staff opened the queue: approving would clear what staff never saw.
        raise ApiError(409, "changed_since_review")
    # Back where it came from: a pair its seller paused stays paused, one with nothing to sell is sold.
    listing.status, missing = back_from_hold(cfg, listing)
    listing.held_from, listing.held_for = None, None
    settle_stock_status(listing)  # back_from_hold settled it already; kept so stock decides in one place
    # Remember what was cleared so pausing and republishing does not queue the same listing again.
    listing.moderation_cleared = ",".join(sorted(set(split_codes(listing.moderation_cleared))
                                                 | set(split_codes(listing.moderation_flags)))) or None
    listing.moderation_note = None
    services.audit(db, staff.id, "approve_listing", f"listing:{listing.id}", listing.moderation_flags or "")
    if listing.status == "published":
        announce(db, listing)
        services.tell_back_in_stock(db, listing)
        services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» тексеруден өтті және сатылымда.",
                        f"«{listing.title}» прошёл проверку и уже продаётся.",
                        f"“{listing.title}” passed review and is on sale.", listing_id=listing.id)
    elif listing.status == "sold" or missing == "out_of_stock":
        services.notify(db, listing.seller_id, "moderation",
                        f"«{listing.title}» тексеруден өтті. Жұп қосып, сатылымға шығарыңыз.",
                        f"«{listing.title}» прошёл проверку. Добавьте пары и выставьте его в продажу.",
                        f"“{listing.title}” passed review. Add pairs and put it on sale.", listing_id=listing.id)
    elif missing:
        services.notify(db, listing.seller_id, "moderation",
                        f"«{listing.title}» тексеруден өтті. Ашып, жетпейтінін толтырыңыз да, "
                        f"«Сатылымға шығару» басыңыз.",
                        f"«{listing.title}» прошёл проверку. Откройте его, дополните недостающее и нажмите "
                        f"«Выставить на продажу».",
                        f"“{listing.title}” passed review. Open it, add what is missing and tap “List for sale”.",
                        listing_id=listing.id)
    else:
        services.notify(db, listing.seller_id, "moderation",
                        f"«{listing.title}» тексеруден өтті. Сату үшін «Сатылымға шығару» басыңыз.",
                        f"«{listing.title}» прошёл проверку. Чтобы продавать, нажмите «Выставить на продажу».",
                        f"“{listing.title}” passed review. To sell it, tap “List for sale”.", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@router.post("/admin/moderation/{listing_id}/reject")
def reject_listing(listing_id: int, body: ModerationRejectIn, staff: User = Depends(staff_user),
                   db: Session = Depends(get_db)):
    listing = queued_listing(db, listing_id)
    reason = body.reason.strip()
    listing.status, listing.moderation_note, listing.held_from, listing.held_for = "rejected", reason, None, None
    services.audit(db, staff.id, "reject_listing", f"listing:{listing.id}", reason)
    services.notify(db, listing.seller_id, "moderation", f"«{listing.title}» қайтарылды: {reason}",
                    f"«{listing.title}» возвращён: {reason}",
                    f"“{listing.title}” was sent back: {reason}", listing_id=listing.id)
    db.commit()
    return {"id": listing.id, "status": listing.status}


@router.get("/admin/reports")
def admin_reports(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Open reports grouped by listing, most-reported first."""
    rows = db.scalars(select(ListingReport).where(ListingReport.status == "open").order_by(ListingReport.id)).all()
    by_listing: dict[int, list[ListingReport]] = {}
    for r in rows:
        by_listing.setdefault(r.listing_id, []).append(r)
    # The reported listings in one query, their photos as plain rows: not three reads a listing.
    listings = {row.id: row for row in with_light_media(db, db.scalars(
        select(Listing).options(LIGHT).where(Listing.id.in_(list(by_listing)))).all())}
    preload_sellers(db, {row.seller_id for row in listings.values()})  # reported listings are from many shops
    items = [{"listing": listing_out(db, listings[lid]),
              "reports": [{"id": r.id, "reason": r.reason, "text": r.text, "reporter_id": r.reporter_id,
                           "at": services.aware(r.created_at).isoformat()} for r in reports]}
             for lid, reports in by_listing.items() if lid in listings]
    items.sort(key=lambda i: -len(i["reports"]))
    return {"items": items}


@router.post("/admin/reports/{listing_id}/close")
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


@router.get("/admin/audit")
def admin_audit(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(AuditLog).order_by(AuditLog.id.desc()).limit(100)).all()
    return {"items": [{"actor_user_id": r.actor_user_id, "action": r.action, "target": r.target, "reason": r.reason,
                       "at": services.aware(r.at).isoformat()} for r in rows]}


@router.get("/admin/orders/{order_id}/evidence")
def order_evidence(order_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db),
                   files: Storage = Depends(get_private)):
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
            "listing_details": ordered_details(order), "evidence": order_evidence_list(db, order, files),
            "evidence_until": (until.isoformat() if (until := dispute_evidence_until(db, order)) else None),
            "evidence_requests": [{"reason": r.reason, "at": services.aware(r.at).isoformat()} for r in db.scalars(
                select(AuditLog).where(AuditLog.action == "request_evidence", AuditLog.target == f"order:{order.id}")
                .order_by(AuditLog.id)).all()],
            "authenticity_proofs": [private_link(files, p.url) for p in db.scalars(select(AuthProof).where(
                AuthProof.listing_id == order.listing_id).order_by(AuthProof.id)).all()],
            "delivery_city": order.delivery_city,
            "delivered_at": services.aware(order.delivered_at).isoformat() if order.delivered_at else None,
            "statements": [{"actor": e.actor, "status": e.to_status, "reason": e.reason,
                            "at": services.aware(e.at).isoformat()} for e in events if e.reason],
            "messages": [{"from": "buyer" if m.sender_id == order.buyer_id else "seller", "body": m.body,
                          "photo_url": m.photo_url, "at": services.aware(m.created_at).isoformat()} for m in messages]}


@router.get("/admin/orders/{order_id}/ledger")
def order_ledger(order_id: int, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    from .models import LedgerTx
    txs = db.scalars(select(LedgerTx).where(LedgerTx.order_id == order_id).order_by(LedgerTx.id)).all()
    return {"transactions": [{"kind": t.kind, "actor": t.actor, "reason": t.reason,
                              "entries": [{"account": e.account, "debit": e.debit, "credit": e.credit} for e in t.entries]}
                             for t in txs]}
