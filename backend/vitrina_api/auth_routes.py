"""Sign-in by SMS code, sessions, the profile and becoming a seller."""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import logging
import math
import re
import secrets
import threading
import time
from datetime import date, timedelta

from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, or_, select, text as sql_text, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus as S

from . import services
from . import offers, payouts
from .config import Settings
from .deps import current_sign_in, current_user, get_db, get_settings, now_utc, sha256
from .errors import ApiError
from .social import find_contact
from .models import (Block, Follow, Notification, Offer, SavedSearch, StockAlert, AuthToken, Favorite, Listing, Order,
                     OtpCode, PayoutAccount, PushDevice, User)
from .api_common import ALMATY, PHONE_RE
from .schemas import OtpRequest, OtpVerify, ProfilePatch, SellerOn
from .serializers import me_out
from .sms import SmsError, otp_text


log = logging.getLogger("vitrina.auth")
router = APIRouter(prefix="/api/v1")


# Per client address (an IPv6 one by its /64, which one machine holds whole). Phones on mobile data share a few
# carrier addresses (CGNAT), so this is set for a crowd; the per-phone limits and the daily cap on codes to new
# numbers (VITRINA_SMS_PER_DAY) do the real guarding.
OTP_REQUESTS_PER_ADDRESS_PER_HOUR = 120
# Codes go only to Kazakhstan numbers (+7 6xx and 7xx): a Russian +7 number costs an international SMS and is the
# usual target of SMS pumping.
KZ_PHONE_RE = re.compile(r"^\+7[67]\d{9}$")
OTP_FAILURES_PER_DAY = 15
STAFF_TOKEN_TTL = timedelta(hours=12)


# One phone's checks and its new code are one step: parallel requests must not all pass "no code in the last minute".
# The striped locks cover one process (and SQLite); PostgreSQL also takes a lock that every API process shares.
_PHONE_LOCKS = [threading.Lock() for _ in range(64)]


def lock_phone(db: Session, phone: str) -> threading.Lock:
    if db.get_bind().dialect.name == "postgresql":
        db.execute(sql_text("SELECT pg_advisory_xact_lock(hashtext(:p))"), {"p": "otp:" + phone})
    return _PHONE_LOCKS[int(hashlib.sha256(phone.encode()).hexdigest(), 16) % len(_PHONE_LOCKS)]


def client_key(request: Request) -> str:
    host = request.client.host if request.client else "unknown"
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return host
    return str(ipaddress.ip_network(f"{ip}/64", strict=False)) if ip.version == 6 else host


def seconds_until(moment, now) -> int:
    return max(1, math.ceil((services.aware(moment) - now).total_seconds()))


@router.post("/auth/otp")
def request_otp(body: OtpRequest, request: Request, db: Session = Depends(get_db),
                cfg: Settings = Depends(get_settings)):
    if not PHONE_RE.match(body.phone) or not KZ_PHONE_RE.match(body.phone):
        raise ApiError(422, "invalid_phone")
    with lock_phone(db, body.phone):
        now = now_utc()
        hour = select(OtpCode.created_at).where(OtpCode.phone == body.phone,
                                                OtpCode.created_at > now - timedelta(hours=1))
        recent = db.scalars(hour.order_by(OtpCode.created_at)).all()
        # A fresh code resets the attempt counter, so wrong guesses are also capped per phone per day.
        day = (OtpCode.phone == body.phone, OtpCode.created_at > now - timedelta(days=1))
        failed_today = db.scalar(select(func.coalesce(func.sum(OtpCode.attempts), 0)).where(*day))
        # detail: seconds until a new code is possible, so the app can count down instead of inviting more taps.
        if failed_today >= OTP_FAILURES_PER_DAY:
            first = db.scalar(select(func.min(OtpCode.created_at)).where(*day, OtpCode.attempts > 0))
            raise ApiError(429, "rate_limited", str(seconds_until(first + timedelta(days=1), now)))
        if len(recent) >= cfg.otp_per_phone_per_hour:
            raise ApiError(429, "rate_limited", str(seconds_until(recent[0] + timedelta(hours=1), now)))
        # Only a code that can still be typed makes the next one wait: after signing in, or after a code was
        # locked by wrong guesses, a new one is sent at once.
        live = db.scalar(select(func.max(OtpCode.created_at)).where(
            OtpCode.phone == body.phone, OtpCode.used.is_(False), OtpCode.attempts < cfg.otp_max_attempts,
            OtpCode.expires_at > now))
        if live is not None and services.aware(live) + cfg.otp_resend_after > now:
            raise ApiError(429, "otp_too_soon", str(seconds_until(live + cfg.otp_resend_after, now)))
        sender = request.app.state.sms
        # The daily cap counts and stops only numbers with no account yet, so someone cycling through numbers can
        # pause sign-ups at worst, never sign-in for the people already here.
        if sender is not None and db.scalar(select(User.id).where(User.phone == body.phone)) is None:
            new_today = select(OtpCode.created_at).where(OtpCode.created_at > now - timedelta(days=1),
                                                         OtpCode.phone.not_in(select(User.phone)))
            if db.scalar(select(func.count()).select_from(new_today.subquery())) >= cfg.sms_per_day:
                log.error("sign-in codes: the daily cap of %s SMS to new numbers is reached (VITRINA_SMS_PER_DAY)",
                          cfg.sms_per_day)
                oldest = db.scalar(select(func.min(new_today.subquery().c.created_at)))
                raise ApiError(503, "signup_paused", str(seconds_until(oldest + timedelta(days=1), now)))
        # Counted only when a code is really sent: refusals above cost no SMS and do not use up the address.
        client = client_key(request)
        if not request.app.state.otp_limiter.allow(client, time.monotonic()):
            raise ApiError(429, "rate_limited")
        code = f"{secrets.randbelow(10**6):06d}"
        digest = hmac.new(cfg.otp_secret, f"{body.phone}:{code}".encode(), hashlib.sha256).hexdigest()
        otp = OtpCode(phone=body.phone, code_hash=digest, expires_at=now + cfg.otp_ttl)
        db.add(otp)
        db.commit()
    if sender is not None:
        try:
            sender.send(body.phone, otp_text(code))
        except SmsError as e:
            masked = f"{body.phone[:4]}…{body.phone[-2:]}"
            if e.maybe_sent:
                # It may still arrive: the code stays valid and counted, and the person can ask again in a minute.
                log.warning("sign-in code to %s maybe not sent: %s", masked, e)
            else:
                # The code never went out: it is taken back, so it neither waits out "send again" nor counts as
                # sent, nor uses up the address.
                log.error("sign-in code to %s not sent: %s", masked, e)
                db.execute(delete(OtpCode).where(OtpCode.id == otp.id))
                db.commit()
                request.app.state.otp_limiter.give_back(client)
                raise ApiError(503, "sms_failed")
    return {"sent": True, "resend_after": math.ceil(cfg.otp_resend_after.total_seconds()),
            **({"dev_code": code} if cfg.debug_otp else {})}


@router.post("/auth/verify")
def verify_otp(body: OtpVerify, db: Session = Depends(get_db), cfg: Settings = Depends(get_settings)):
    # Every code still alive counts: when the first SMS arrives after "send again", the person types that one.
    # At most a handful are alive (one a minute, five an hour), and wrong guesses stay capped per code and per day.
    live = db.scalars(select(OtpCode).where(
        OtpCode.phone == body.phone, OtpCode.used.is_(False), OtpCode.attempts < cfg.otp_max_attempts,
        OtpCode.expires_at > now_utc()).order_by(OtpCode.id.desc())).all()
    if not live:
        locked = db.scalar(select(OtpCode.id).where(
            OtpCode.phone == body.phone, OtpCode.used.is_(False), OtpCode.expires_at > now_utc()).limit(1))
        # A code still in time but typed wrong too often is not "expired": the person was not slow, just unlucky.
        raise ApiError(400, "otp_locked" if locked else "otp_expired")
    digest = hmac.new(cfg.otp_secret, f"{body.phone}:{body.code}".encode(), hashlib.sha256).hexdigest()
    otp = next((o for o in live if hmac.compare_digest(digest, o.code_hash)), None)
    if otp is None:
        # One atomic step on the newest code, so parallel guesses cannot all pass the attempts check read above.
        db.execute(update(OtpCode).where(OtpCode.id == live[0].id, OtpCode.attempts < cfg.otp_max_attempts)
                   .values(attempts=OtpCode.attempts + 1))
        db.commit()
        raise ApiError(400, "otp_invalid")
    claimed = db.execute(update(OtpCode).where(OtpCode.id == otp.id, OtpCode.used.is_(False),
                                               OtpCode.attempts < cfg.otp_max_attempts).values(used=True))
    if claimed.rowcount != 1:  # used or locked by a request that got there first
        db.rollback()
        raise ApiError(400, "otp_expired")
    # Signed in: the other codes of this phone are spent too.
    db.execute(update(OtpCode).where(OtpCode.phone == body.phone, OtpCode.used.is_(False)).values(used=True))
    otp.used = True
    user = db.scalar(select(User).where(User.phone == body.phone))
    if user is None:
        user = User(phone=body.phone)
        db.add(user)
        db.flush()
    if user.is_blocked:
        db.commit()
        raise ApiError(403, "account_blocked", cfg.support_contact or None)  # where to write, when it is set
    raw = secrets.token_urlsafe(32)
    # Staff can move money and hide listings, so a leaked staff token is worth far less if it dies within a shift.
    ttl = STAFF_TOKEN_TTL if user.role in ("support", "admin") else cfg.token_ttl
    db.add(AuthToken(token_hash=sha256(raw), user_id=user.id, expires_at=now_utc() + ttl))
    db.commit()
    return {"token": raw, "user": me_out(user)}


@router.post("/auth/logout")
def logout(everywhere: bool = False, authorization: str | None = Header(default=None),
           user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Ends this session on the server, not only on the phone; with everywhere, every session of the account."""
    which = (AuthToken.user_id == user.id if everywhere
             else AuthToken.token_hash == sha256((authorization or "")[7:].strip()))
    # The phones signed in that way hear no more alerts of this account.
    db.execute(delete(PushDevice).where(PushDevice.auth_token_id.in_(select(AuthToken.id).where(which))))
    db.execute(update(AuthToken).where(which).values(revoked=True))
    db.commit()
    return {"ok": True}


class PushIn(BaseModel):
    # A Firebase Cloud Messaging registration token, as the phone's Firebase gives it.
    token: str = Field(min_length=20, max_length=400, pattern=r"^[A-Za-z0-9_:.\-]+$")
    lang: str = Field(default="kk", pattern="^(kk|ru|en)$")


@router.put("/me/push", status_code=204)
def put_push(body: PushIn, sign_in: AuthToken = Depends(current_sign_in), db: Session = Depends(get_db),
             cfg: Settings = Depends(get_settings)):
    """This phone takes alerts while the app is closed, in the app's language, for as long as this sign-in lasts.
    Sent at every start of the app, after sign-in, when Firebase gives the phone a new token and when the language
    changes. A token already known moves to this sign-in: the phone now belongs to whoever signed in on it last."""
    now = now_utc()
    # A seller who waits for the phone to ring would hear nothing once the sign-in ends, and not know why: a phone
    # that keeps opening the app (a tapped alert opens it) keeps its sign-in. Staff sign-ins stay short.
    staff = db.get(User, sign_in.user_id).role in ("support", "admin")
    for attempt in (1, 2):
        if not staff and services.aware(sign_in.expires_at) < now + cfg.token_ttl / 2:
            sign_in.expires_at = now + cfg.token_ttl
        # One phone per sign-in: a new token of the same phone replaces its old one.
        db.execute(delete(PushDevice).where(PushDevice.auth_token_id == sign_in.id, PushDevice.token != body.token))
        device = db.scalar(select(PushDevice).where(PushDevice.token == body.token))
        if device is None:
            db.add(PushDevice(token=body.token, user_id=sign_in.user_id, auth_token_id=sign_in.id, lang=body.lang,
                              created_at=now, updated_at=now))
        else:
            device.user_id, device.auth_token_id, device.lang, device.updated_at = (
                sign_in.user_id, sign_in.id, body.lang, now)
        try:
            db.commit()
            return
        except IntegrityError:  # the same phone sent its token twice at once: the other one is there now
            db.rollback()
            if attempt == 2:
                raise


@router.delete("/me/push", status_code=204)
def delete_push(sign_in: AuthToken = Depends(current_sign_in), db: Session = Depends(get_db)):
    """This phone takes no more alerts (the person turned them off on the phone)."""
    db.execute(delete(PushDevice).where(PushDevice.auth_token_id == sign_in.id))
    db.commit()


@router.get("/app-config")
def app_config(cfg: Settings = Depends(get_settings)):
    """What the app shows depending on the server: without online payment, a chat with the seller replaces
    ordering and price offers."""
    return {"payments": cfg.payments != "off"}


@router.get("/health")
def health(db: Session = Depends(get_db)):
    """For the load balancer and uptime checks: the process answers and the database does too."""
    try:
        db.execute(select(1))
    except Exception:
        raise ApiError(503, "unavailable")
    return {"ok": True}


@router.get("/me")
def get_me(user: User = Depends(current_user)):
    return me_out(user)


def notification_settings(user: User) -> dict:
    off = services.muted(user)
    return {"items": [{"kind": k, "on": k not in off} for k in services.OPTIONAL_KINDS]}


@router.get("/me/notification-settings")
def get_notification_settings(user: User = Depends(current_user)):
    return notification_settings(user)


@router.put("/me/notification-settings")
def put_notification_settings(body: dict[str, bool], user: User = Depends(current_user),
                              db: Session = Depends(get_db)):
    """Turns optional alerts on or off, e.g. {"price_drop": false}. Kinds that always arrive cannot be listed."""
    unknown = set(body) - set(services.OPTIONAL_KINDS)
    if unknown:
        raise ApiError(422, "validation", f"cannot mute {sorted(unknown)}")
    off = services.muted(user)
    for kind, on in body.items():
        (off.discard if on else off.add)(kind)
    user.muted_kinds = ",".join(sorted(off)) or None
    db.commit()
    return notification_settings(user)


@router.delete("/me")
def delete_me(user: User = Depends(current_user), db: Session = Depends(get_db)):
    delete_account(db, user)
    return {"deleted": True}


def delete_account(db: Session, user: User) -> None:
    """Deletes the account: personal data goes, the person is signed out everywhere and their listings leave the
    catalog. Orders, payments and the ledger stay, without the name, because the law requires keeping them.
    Also run by support for someone who cannot open the app: `python -m vitrina_api.delete_account`."""
    open_orders = db.scalar(select(func.count(Order.id)).where(
        or_(Order.buyer_id == user.id, Order.seller_id == user.id),
        Order.status.not_in([s.value for s in (S.COMPLETED, S.REFUNDED, S.CANCELLED)])))
    if open_orders:
        raise ApiError(409, "open_orders")
    from vitrina_core.money import seller_payable
    if services.balance(db, seller_payable(str(user.id))) > 0 or payouts.open_payout(db, user.id) is not None:
        raise ApiError(409, "payout_owed")
    now = now_utc()
    for model, column in ((Favorite, Favorite.user_id), (SavedSearch, SavedSearch.user_id),
                          (Follow, Follow.user_id), (Follow, Follow.seller_id), (StockAlert, StockAlert.user_id),
                          (Notification, Notification.user_id), (PushDevice, PushDevice.user_id),
                          (Block, Block.user_id), (Block, Block.blocked_id),
                          # Bank details: each payout already made keeps its own copy, as the ledger needs.
                          (PayoutAccount, PayoutAccount.seller_id)):
        db.execute(delete(model).where(column == user.id))
    db.execute(update(AuthToken).where(AuthToken.user_id == user.id).values(revoked=True))
    db.execute(update(Offer).where(or_(Offer.buyer_id == user.id, Offer.seller_id == user.id),
                                   Offer.status.in_(offers.OPEN)).values(status="withdrawn"))
    db.execute(update(Listing).where(Listing.seller_id == user.id, Listing.status.not_in(("sold", "hidden")))
               .values(status="paused"))
    services.audit(db, user.id, "delete_account", f"user:{user.id}")
    user.phone = f"deleted:{user.id}"  # frees the number: signing in with it again starts a new account
    user.display_name = user.city = user.shop_name = user.shop_about = user.last_delivery = user.away_until = None
    user.is_blocked, user.deleted_at = True, now
    db.commit()


@router.patch("/me")
def patch_me(body: ProfilePatch, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user = db.merge(user)
    for k, v in body.model_dump(exclude_unset=True).items():
        setattr(user, k, v)
    db.commit()
    return me_out(user)


MAX_AWAY_DAYS = 60


class AwayIn(BaseModel):
    until: date | None = None  # None ends the holiday


@router.put("/me/away")
def set_away(body: AwayIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Holiday mode: listings stay visible with a note, but nobody can order or make an offer until the seller
    is back, so no one pays and then waits for a shop that is closed."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    today = now_utc().astimezone(ALMATY).date()
    if body.until is not None and not today <= body.until <= today + timedelta(days=MAX_AWAY_DAYS):
        raise ApiError(422, "validation", f"until must be within {MAX_AWAY_DAYS} days from today")
    user = db.merge(user)
    user.away_until = body.until
    db.commit()
    return me_out(user)


MAX_SHOP_ABOUT = 500


class ShopAboutIn(BaseModel):
    text: str | None = Field(default=None, max_length=MAX_SHOP_ABOUT)


@router.put("/me/shop-about")
def set_shop_about(body: ShopAboutIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """A few lines on the shop page: how the seller ships, returns, answers. Contacts stay in the app's chat."""
    if not user.is_seller:
        raise ApiError(403, "seller_required")
    text = (body.text or "").strip() or None
    if found := find_contact(text):
        raise ApiError(422, "contacts_not_allowed", found)
    user = db.merge(user)
    user.shop_about = text
    db.commit()
    return me_out(user)


@router.post("/me/seller")
def become_seller(body: SellerOn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user = db.merge(user)
    user.is_seller, user.shop_name, user.city = True, body.shop_name, body.city
    db.commit()
    return me_out(user)
