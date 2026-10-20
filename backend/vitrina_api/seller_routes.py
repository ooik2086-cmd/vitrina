"""The seller side: own listings, earnings and the sales export, the shop page, followers, to-dos and analytics."""
from __future__ import annotations

import collections
import csv
import io
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query
from fastapi.responses import Response
from sqlalchemy import String, case, cast, func, literal, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from vitrina_core.orders import OrderStatus as S

from . import services
from . import delivery_eta
from .deps import current_user, get_db, now_utc, optional_user
from .errors import ApiError
from .social import reply_time, seller_rating
from .models import Follow, Offer, ListingDailyViews, Favorite, Listing, ListingSize, Order, Question, User
from .api_common import ALMATY
from .serializers import ADDRESS_HIDDEN_UNTIL_PAID, LIGHT, away_out, listing_out, with_light_media


router = APIRouter(prefix="/api/v1")


@router.get("/me/listings")
def my_listings(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = with_light_media(db, db.scalars(select(Listing).options(LIGHT).where(Listing.seller_id == user.id)
                                           .order_by(Listing.id.desc()).limit(200)).all())
    preload_stats(db, [r.id for r in rows])
    return {"items": [listing_out(db, r, owner=True) for r in rows]}


def preload_stats(db: Session, ids: list[int]) -> None:
    """listing_stats for many listings in four grouped queries instead of four per listing."""
    from .models import Conversation
    if not ids:
        return
    def grouped(column, *where):
        return dict(db.execute(select(column, func.count()).where(column.in_(ids), *where).group_by(column)).all())
    favs = grouped(Favorite.listing_id)
    chats = grouped(Conversation.listing_id)
    orders = grouped(Order.listing_id, Order.status != S.CANCELLED.value)
    sold = grouped(Order.listing_id, Order.status == S.COMPLETED.value)
    db.info["listing_stats"] = {i: {"favorites": favs.get(i, 0), "chats": chats.get(i, 0), "orders": orders.get(i, 0),
                                    "sold": sold.get(i, 0)} for i in ids}


@router.get("/me/earnings")
def my_earnings(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Seller's money, read straight from the ledger: what is held for open orders, what is owed to the
    seller after completed ones, and the commission taken on each."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    from vitrina_core.money import PLATFORM_FEE, escrow, seller_payable
    from .models import LedgerEntry, LedgerTx
    orders = {o.id: o for o in db.scalars(select(Order).where(Order.seller_id == user.id)).all()}
    # Every order's escrow account in one sum, not one query an order.
    escrows = select(literal(escrow("")) + cast(Order.id, String)).where(Order.seller_id == user.id)
    held = int(db.scalar(select(func.coalesce(func.sum(LedgerEntry.credit - LedgerEntry.debit), 0))
                         .where(LedgerEntry.account.in_(escrows))) or 0)
    items = []
    if orders:
        txs = db.scalars(select(LedgerTx).where(LedgerTx.order_id.in_(orders),
                                                LedgerTx.idempotency_key.like("settle:%"))
                         .options(selectinload(LedgerTx.entries))
                         .order_by(LedgerTx.id.desc()).limit(100)).all()
        untitled = {orders[tx.order_id].listing_id for tx in txs if not orders[tx.order_id].listing_title}
        titles = dict(db.execute(select(Listing.id, Listing.title).where(Listing.id.in_(untitled))).all()) \
            if untitled else {}
        mine = seller_payable(str(user.id))
        for tx in txs:
            net = sum(e.credit - e.debit for e in tx.entries if e.account == mine)
            fee = sum(e.credit - e.debit for e in tx.entries if e.account == PLATFORM_FEE)
            order = orders[tx.order_id]
            items.append({"order_id": order.id, "kind": tx.kind, "at": services.aware(tx.at).isoformat(),
                          "listing_title": order.listing_title or titles[order.listing_id],
                          "net_tiyn": net, "fee_tiyn": fee})
    fees = db.scalar(select(func.coalesce(func.sum(LedgerEntry.credit - LedgerEntry.debit), 0))
                     .join(LedgerTx, LedgerTx.id == LedgerEntry.tx_id)
                     .where(LedgerEntry.account == PLATFORM_FEE, LedgerTx.order_id.in_(orders or [0])))
    return {"held_tiyn": held, "payable_tiyn": services.balance(db, seller_payable(str(user.id))),
            "fees_tiyn": int(fees or 0), "items": items}


STATUS_KK = {
    "CREATED": "Жасалды", "PAYMENT_PENDING": "Төлем күтілуде", "PAID": "Төленді", "SELLER_ACCEPTED": "Қабылданды",
    "PREPARING": "Дайындалуда", "SHIPPED": "Жіберілді", "IN_TRANSIT": "Жолда",
    "DELIVERED_PENDING_CONFIRMATION": "Жеткізілді", "COMPLETED": "Аяқталды", "DISPUTED": "Дау",
    "RETURN_REQUESTED": "Қайтару сұралды", "REFUND_PENDING": "Ақша қайтарылуда", "REFUNDED": "Ақша қайтарылды",
    "CANCELLED": "Бас тартылды",
}


def tenge(tiyn: int | None) -> str:
    """Tenge for a spreadsheet in Kazakhstan: decimal comma, no thousands separator."""
    if tiyn is None:
        return ""
    whole, part = divmod(abs(tiyn), 100)
    return ("-" if tiyn < 0 else "") + (f"{whole},{part:02d}" if part else str(whole))


@router.get("/me/sales.csv")
def sales_csv(days: int = Query(default=90, ge=1, le=366), user: User = Depends(current_user),
              db: Session = Depends(get_db)):
    """The seller's orders for a spreadsheet or an accountant: price, promo, commission and what was paid out.
    Semicolons and a byte-order mark so Excel opens it right in a Russian or Kazakh locale."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    from vitrina_core.money import PLATFORM_FEE, seller_payable
    from .models import LedgerTx
    since = now_utc() - timedelta(days=days)
    mine_since = (Order.seller_id == user.id, Order.created_at >= since)
    orders = db.scalars(select(Order).where(*mine_since).order_by(Order.id)).all()
    # A year of orders is read in four queries, not six an order: titles, sizes and settlements for all of them.
    picked = select(Order.id).where(*mine_since)
    titles = dict(db.execute(select(Listing.id, Listing.title).where(
        Listing.id.in_(select(Order.listing_id).where(*mine_since)))).all())
    sizes = dict(db.execute(select(ListingSize.id, ListingSize.label).where(
        ListingSize.id.in_(select(Order.size_id).where(*mine_since)))).all())
    settlements = collections.defaultdict(list)
    for tx in db.scalars(select(LedgerTx).where(LedgerTx.order_id.in_(picked),
                                                LedgerTx.idempotency_key.like("settle:%"))
                         .options(selectinload(LedgerTx.entries))):
        settlements[tx.order_id].append(tx)
    mine = seller_payable(str(user.id))
    out = io.StringIO()
    w = csv.writer(out, delimiter=";", lineterminator="\r\n")

    def cell(text: str) -> str:
        # Text someone else typed must never run as a spreadsheet formula when the seller opens the file.
        return "'" + text if text[:1] in ("=", "+", "-", "@", "\t", "\r") else text

    w.writerow(["Тапсырыс", "Күні", "Күйі", "Тауар", "Өлшем", "Тауар бағасы, ₸", "Промокод", "Жеңілдік, ₸",
                "Жеткізу, ₸", "Комиссия, ₸", "Сізге, ₸", "Алушы қаласы"])
    for o in orders:
        settled = settlements[o.id]
        fee = sum(e.credit - e.debit for tx in settled for e in tx.entries if e.account == PLATFORM_FEE)
        net = sum(e.credit - e.debit for tx in settled for e in tx.entries if e.account == mine)
        size = sizes.get(o.size_id)
        paid = o.status not in ADDRESS_HIDDEN_UNTIL_PAID  # the buyer's city only once they have paid
        w.writerow([o.id, services.aware(o.created_at).astimezone(ALMATY).strftime("%d.%m.%Y %H:%M"),
                    STATUS_KK.get(o.status, o.status), cell(titles[o.listing_id]),
                    cell(size) if size is not None else "",
                    tenge(o.item_price_tiyn), o.promo_code or "", tenge(o.promo_discount_tiyn) if o.promo_code else "",
                    tenge(o.delivery_price_tiyn), tenge(fee) if settled else "", tenge(net) if settled else "",
                    cell(o.delivery_city or "") if paid else ""])
    name = f"vitrina-sales-{now_utc().astimezone(ALMATY):%Y-%m-%d}.csv"
    return Response(content="\ufeff" + out.getvalue(), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


def public_seller(db: Session, seller_id: int) -> User:
    seller = db.get(User, seller_id)
    if seller is None or not seller.is_seller or seller.is_blocked:
        raise ApiError(404, "not_found")
    return seller


def followers(db: Session, seller_id: int) -> int:
    return int(db.scalar(select(func.count(Follow.id)).where(Follow.seller_id == seller_id)) or 0)


@router.get("/sellers/{seller_id}")
def seller_profile(seller_id: int, user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    """Public shop card. Counts come from the platform's own records, not from what the seller typed."""
    seller = public_seller(db, seller_id)
    sales = db.scalar(select(func.count(Order.id)).where(Order.seller_id == seller.id,
                                                         Order.status == S.COMPLETED.value))
    live = db.scalar(select(func.count(Listing.id)).where(Listing.seller_id == seller.id,
                                                          Listing.status == "published"))
    return {"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
            "since": services.aware(seller.created_at).date().isoformat(),
            "completed_sales": int(sales or 0), "listings": int(live or 0), "away_until": away_out(seller),
            "about": seller.shop_about,
            "followers": followers(db, seller.id), "reply_time": reply_time(db, seller.id),
            "ship_time": delivery_eta.ship_time(db, seller.id),
            "following": user is not None and db.scalar(select(Follow.id).where(
                Follow.user_id == user.id, Follow.seller_id == seller.id)) is not None,
            **seller_rating(db, seller.id)}


@router.put("/sellers/{seller_id}/follow")
def follow_seller(seller_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller = public_seller(db, seller_id)
    if seller.id == user.id:
        raise ApiError(409, "own_shop")
    if db.scalar(select(Follow.id).where(Follow.user_id == user.id, Follow.seller_id == seller.id)) is None:
        db.add(Follow(user_id=user.id, seller_id=seller.id))
        try:
            db.commit()
        except IntegrityError:  # a double tap; the follow is there either way
            db.rollback()
    return {"following": True, "followers": followers(db, seller.id)}


@router.delete("/sellers/{seller_id}/follow")
def unfollow_seller(seller_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    for f in db.scalars(select(Follow).where(Follow.user_id == user.id, Follow.seller_id == seller_id)).all():
        db.delete(f)
    db.commit()
    return {"following": False, "followers": followers(db, seller_id)}


@router.get("/me/following")
def my_following(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Shops the user follows, newest first, with how many listings each has on sale now."""
    rows = db.execute(select(User, Follow.created_at).join(Follow, Follow.seller_id == User.id).where(
        Follow.user_id == user.id, User.is_blocked.is_(False)).order_by(Follow.id.desc())).all()
    items = []
    for seller, _ in rows:
        live = db.scalar(select(func.count(Listing.id)).where(Listing.seller_id == seller.id,
                                                              Listing.status == "published"))
        items.append({"id": seller.id, "shop_name": seller.shop_name, "city": seller.city,
                      "listings": int(live or 0), "away_until": away_out(seller), **seller_rating(db, seller.id)})
    return {"items": items}


def unread_messages(db: Session, user_id: int) -> int:
    """Messages from the other side this person has not opened yet, across all their chats."""
    from .models import Conversation, Message
    last_read = case((Conversation.buyer_id == user_id, Conversation.buyer_last_read_id),
                     else_=Conversation.seller_last_read_id)
    return int(db.scalar(select(func.count(Message.id)).join(Conversation, Conversation.id == Message.conversation_id)
                         .where(or_(Conversation.buyer_id == user_id, Conversation.seller_id == user_id),
                                Message.sender_id != user_id, Message.id > last_read)) or 0)


@router.get("/me/todo")
def my_todo(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """What waits on this person right now, as counts for the profile's to-do card. Seller lines come only for
    sellers. Offers past their answer time are not counted: they have already lapsed."""
    def orders(role, *statuses):
        who = Order.seller_id if role == "seller" else Order.buyer_id
        return int(db.scalar(select(func.count(Order.id)).where(who == user.id, Order.status.in_(statuses))) or 0)

    now = now_utc()
    out = {
        "to_pay": orders("buyer", S.CREATED.value, S.PAYMENT_PENDING.value),
        "to_confirm": orders("buyer", S.DELIVERED_PENDING_CONFIRMATION.value),
        "offers_answered": int(db.scalar(select(func.count(Offer.id)).where(
            Offer.buyer_id == user.id, Offer.status.in_(("countered", "accepted")), Offer.expires_at > now)) or 0),
        "unread_messages": unread_messages(db, user.id),
    }
    if user.is_seller:
        out |= {
            "to_accept": orders("seller", S.PAID.value),
            "to_ship": orders("seller", S.SELLER_ACCEPTED.value, S.PREPARING.value),
            "returns": orders("seller", S.RETURN_REQUESTED.value),
            "questions": int(db.scalar(select(func.count(Question.id)).join(Listing, Listing.id == Question.listing_id)
                                       .where(Listing.seller_id == user.id, Question.answer.is_(None),
                                              Question.hidden.is_(False))) or 0),
            "offers": int(db.scalar(select(func.count(Offer.id)).where(
                Offer.seller_id == user.id, Offer.status == "pending", Offer.expires_at > now)) or 0),
        }
    return out


@router.get("/me/analytics")
def seller_analytics(days: int = 14, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Day-by-day views, orders and sales for the seller's listings, plus the listings that draw most interest."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    days = max(7, min(days, 90))
    today = now_utc().astimezone(ALMATY).date()
    first = today - timedelta(days=days - 1)
    listings = {l.id: l for l in db.scalars(select(Listing).where(Listing.seller_id == user.id))}
    per_day = {first + timedelta(days=i): {"views": 0, "orders": 0, "sold_tiyn": 0} for i in range(days)}
    views_by_listing: dict[int, int] = collections.Counter()
    if listings:
        for lid, day, views in db.execute(select(ListingDailyViews.listing_id, ListingDailyViews.day,
                                                 ListingDailyViews.views)
                                          .where(ListingDailyViews.listing_id.in_(listings),
                                                 ListingDailyViews.day >= first)):
            per_day[day]["views"] += views
            views_by_listing[lid] += views
    orders_by_listing: dict[int, int] = collections.Counter()
    since = datetime.combine(first, datetime.min.time(), ALMATY).astimezone(timezone.utc)
    for order in db.scalars(select(Order).where(Order.seller_id == user.id, Order.created_at >= since,
                                                Order.status != S.CANCELLED.value)):
        day = services.aware(order.created_at).astimezone(ALMATY).date()
        if day in per_day:
            per_day[day]["orders"] += 1
            if order.status == S.COMPLETED.value:
                per_day[day]["sold_tiyn"] += order.item_price_tiyn
        orders_by_listing[order.listing_id] += 1
    totals = {k: sum(d[k] for d in per_day.values()) for k in ("views", "orders", "sold_tiyn")}
    totals["conversion"] = round(totals["orders"] / totals["views"], 4) if totals["views"] else None
    top = sorted(listings.values(), key=lambda l: (-views_by_listing[l.id], -orders_by_listing[l.id], -l.id))[:5]
    return {
        "days": [{"date": d.isoformat(), **v} for d, v in per_day.items()],
        "totals": totals,
        "top": [{"id": l.id, "title": l.title, "status": l.status, "views": views_by_listing[l.id],
                 "orders": orders_by_listing[l.id]} for l in top if views_by_listing[l.id] or orders_by_listing[l.id]],
    }
