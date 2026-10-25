"""Alerts on the phone while the app is closed: every new notification also goes to the person's phones through
Firebase Cloud Messaging (FCM), within seconds. Runs in its own process: `python -m vitrina_api.push`.

It needs the Firebase project's service-account key (VITRINA_FCM_CREDENTIALS_FILE, a JSON file from the Firebase
console), looked for every minute. Without it the process only waits: notifications stay in the app's list, as before. The app sends a
phone's token after sign-in (PUT /me/push); the token lives under that sign-in, so signing out stops the alerts.

Each notification is taken once (pushed_at) before it is sent, so two processes never send it twice; one too old
(URGENT_MAX_AGE, NEWS_MAX_AGE) is let go unsent. Quiet kinds wait out the night (QUIET_FROM-QUIET_TO, Almaty).
"""
from __future__ import annotations

import base64
import json
import logging
import signal
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import httpx
from sqlalchemy import case, delete, select, update
from sqlalchemy.orm import sessionmaker

from .api_common import ALMATY
from .config import Settings
from .deps import now_utc
from .models import AuthToken, Notification, PushDevice, User, make_session_factory
from .services import aware

log = logging.getLogger("vitrina_api.push")

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
BATCH = 100
# A send Google could not take (5xx, 429) is tried again after these pauses, then let go.
RETRY_AFTER_S = (2, 8)
# Kinds where someone waits on the person (a buyer's message, an order, money): they ring and pop up, in the
# "Хат пен тапсырыс" channel, at any hour. The rest (a price drop, a new pair, a tip) come quietly, in the
# "Жаңалықтар мен кеңестер" channel, and never at night: they wait for the morning.
URGENT = {"message", "order_status", "offer", "offer_reply", "question", "question_answered", "evidence",
          "evidence_request", "payout", "moderation", "listing_hidden", "authenticity", "sold_out"}
CHANNEL_URGENT = "vitrina_alerts"
CHANNEL_NEWS = "vitrina_news"
# Older than this an alert is let go unsent (the server was down): news that late is noise on a lock screen, and it
# is in the app's list. The quiet kinds may wait out the night.
URGENT_MAX_AGE = timedelta(hours=1)
NEWS_MAX_AGE = timedelta(hours=12)
QUIET_FROM, QUIET_TO = 22, 8  # Almaty hours with no quiet-kind alerts
# Quiet kinds that come in bursts (a shop's sale, a seller listing an evening's pairs): the newest of a kind takes
# the place of the one before in the phone's list.
COLLAPSE = {"price_drop", "followed_shop", "saved_search", "back_in_stock", "review_reminder", "listing_tip"}


def quiet(now: datetime) -> bool:
    hour = now.astimezone(ALMATY).hour
    return hour >= QUIET_FROM or hour < QUIET_TO


@dataclass(frozen=True)
class Credentials:
    project_id: str
    client_email: str
    private_key: str
    token_uri: str


def load_credentials(path: str) -> Credentials | None:
    """The service-account key, or None when no file is named or the named file is not there (push stays off).
    A file that is there but unreadable is an error: someone meant to turn push on."""
    if not path or not Path(path).is_file():
        return None
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("type") != "service_account":
        raise ValueError(f"{path}: not a service-account key (type is {data.get('type')!r})")
    creds = Credentials(project_id=data["project_id"], client_email=data["client_email"],
                        private_key=data["private_key"],
                        token_uri=data.get("token_uri") or "https://oauth2.googleapis.com/token")
    if not creds.token_uri.startswith("https://"):
        raise ValueError(f"{path}: token_uri must use https")
    return creds


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def signed_grant(creds: Credentials, now: float) -> str:
    """The service account's signed request for an access token (OAuth 2.0 JWT bearer grant, RS256)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    key = serialization.load_pem_private_key(creds.private_key.encode(), password=None)
    head = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({"iss": creds.client_email, "scope": SCOPE, "aud": creds.token_uri,
                              "iat": int(now), "exp": int(now) + 3600}).encode())
    signature = key.sign(f"{head}.{claims}".encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{head}.{claims}.{_b64(signature)}"


class Fcm:
    """Sends one message at a time over one kept-open connection; the access token is reused until near its end."""

    def __init__(self, creds: Credentials, client: httpx.Client | None = None):
        self.creds = creds
        self.client = client or httpx.Client(timeout=10)
        self._access: tuple[str, float] | None = None

    def access_token(self) -> str:
        if self._access and self._access[1] > time.time() + 300:
            return self._access[0]
        r = self.client.post(self.creds.token_uri, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": signed_grant(self.creds, time.time())})
        if r.status_code != 200:
            # 4xx: a wrong or revoked key; 5xx: Google's side. Google's answer names the reason, never the key.
            log.error("push: no access token from Google: %s %s", r.status_code, r.text[:200])
            r.raise_for_status()
        body = r.json()
        self._access = (body["access_token"], time.time() + float(body.get("expires_in", 3600)))
        return self._access[0]

    def send(self, message: dict) -> str:
        """"sent", "gone" (the token no longer reaches a phone: forget it), "retry" (Google could not take it now),
        "down" (Google not reached, or no access token: the rest of the batch waits too) or "failed"."""
        url = SEND_URL.format(project=self.creds.project_id)
        try:
            for fresh in (False, True):
                if fresh:
                    self._access = None  # a 401: the token was revoked early; one new token, one more try
                r = self.client.post(url, json={"message": message},
                                     headers={"Authorization": f"Bearer {self.access_token()}"})
                if r.status_code != 401:
                    break
        except httpx.HTTPError as exc:
            log.warning("push: %s", type(exc).__name__)
            return "down"
        if r.status_code == 200:
            return "sent"
        code = error_code(r)
        if r.status_code == 404 or code in ("UNREGISTERED", "SENDER_ID_MISMATCH"):
            return "gone"
        if r.status_code == 429 or r.status_code >= 500:
            return "retry"
        log.warning("push refused: %s %s", r.status_code, code or r.text[:200])
        return "failed"


def error_code(r: httpx.Response) -> str | None:
    try:
        for detail in r.json()["error"].get("details") or []:
            if detail.get("errorCode"):
                return str(detail["errorCode"])
        return str(r.json()["error"].get("status") or "") or None
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def message(n: Notification, token: str, lang: str) -> dict:
    """One phone's alert for [n], in the language the phone's app is in. Its data says what to open on a tap."""
    body = {"ru": n.text_ru or n.text_kk, "en": n.text_en or n.text_ru or n.text_kk}.get(lang, n.text_kk)
    data = {"notification_id": str(n.id), "kind": n.kind}
    for key in ("order_id", "conversation_id", "listing_id"):
        if getattr(n, key) is not None:
            data[key] = str(getattr(n, key))
    urgent = n.kind in URGENT
    android = {"channel_id": CHANNEL_URGENT if urgent else CHANNEL_NEWS}
    # A new alert of the same chat or order takes the place of the one before: one line per chat, not ten.
    if n.conversation_id is not None and n.kind == "message":
        android["tag"] = f"chat-{n.conversation_id}"
    elif n.order_id is not None:
        android["tag"] = f"order-{n.order_id}"
    elif n.kind in COLLAPSE:
        android["tag"] = n.kind
    return {"token": token, "notification": {"body": body}, "data": data,
            "android": {"priority": "HIGH" if urgent else "NORMAL", "notification": android}}


def take(sessions: sessionmaker, now: datetime) -> tuple[int, list[tuple[int, dict, str]]]:
    """Marks the next notifications as taken: how many, and their alerts (notification id, message, phone token).
    Urgent ones first, so a burst of price drops never holds back a buyer's message; at night only urgent ones.
    Taken before sent: a process that stops half way loses a few alerts (they stay in the app), never sends twice."""
    urgent = Notification.kind.in_(URGENT)
    query = select(Notification).where(Notification.pushed_at.is_(None))
    if quiet(now):
        query = query.where(urgent)
    with sessions() as db:
        rows = db.scalars(query.order_by(case((urgent, 0), else_=1), Notification.id).limit(BATCH)
                          .with_for_update(skip_locked=True)).all()
        for n in rows:
            n.pushed_at = now
        fresh = [n for n in rows
                 if aware(n.created_at) >= now - (URGENT_MAX_AGE if n.kind in URGENT else NEWS_MAX_AGE)]
        phones: dict[int, list[PushDevice]] = {}
        if fresh:
            for d in db.scalars(select(PushDevice).join(AuthToken, AuthToken.id == PushDevice.auth_token_id)
                                .join(User, User.id == PushDevice.user_id)
                                .where(PushDevice.user_id.in_({n.user_id for n in fresh}),
                                       AuthToken.revoked.is_(False), AuthToken.expires_at > now,
                                       User.is_blocked.is_(False))):
                phones.setdefault(d.user_id, []).append(d)
        out = [(n.id, message(n, d.token, d.lang), d.token) for n in fresh for d in phones.get(n.user_id, [])]
        db.commit()
    return len(rows), out


def let_go_old(sessions: sessionmaker, now: datetime) -> None:
    """With push off, notifications too old to push are marked, so the index of those not yet taken stays small and
    turning push on later does not send old news."""
    with sessions() as db:
        db.execute(update(Notification).where(Notification.pushed_at.is_(None),
                                              Notification.created_at < now - NEWS_MAX_AGE).values(pushed_at=now))
        db.commit()


def run_once(sessions: sessionmaker, fcm: Fcm, *, now: datetime | None = None, pause=time.sleep) -> tuple[int, int]:
    """One batch: sends what is new and forgets the tokens that no longer reach a phone. How many notifications
    were taken, and how many alerts sent. No access token (a refused key, Google not reached): nothing is taken.
    Google not reached half way: the notifications none of whose alerts went are put back for the next pass."""
    fcm.access_token()
    taken, todo = take(sessions, now or now_utc())
    sent, gone, done = 0, set(), set()
    for wait in (*RETRY_AFTER_S, None):
        again, down = [], False
        for i, (nid, msg, token) in enumerate(todo):
            if token in gone:
                continue
            result = fcm.send(msg)
            if result == "sent":
                sent += 1
                done.add(nid)
            elif result == "gone":
                gone.add(token)
            elif result == "retry":
                again.append((nid, msg, token))
            elif result == "down":
                again.extend(todo[i:])
                down = True
                break
        if not again or wait is None or down:
            break
        pause(wait)
        todo = again
    back = {nid for nid, _, _ in again} - done
    if again:
        log.warning("push: %d alerts not sent now, Firebase did not take them", len(again))
    if gone or back:
        with sessions() as db:
            if gone:
                db.execute(delete(PushDevice).where(PushDevice.token.in_(gone)))
            if back:
                db.execute(update(Notification).where(Notification.id.in_(back)).values(pushed_at=None))
            db.commit()
    return taken, sent


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Settings()
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopping.set())
    alive = Path(cfg.push_alive) if cfg.push_alive else None
    sessions = make_session_factory(cfg.database_url, create_schema=False)
    fcm, said, wait = None, None, cfg.push_interval_s
    while not stopping.is_set():
        if alive:
            alive.touch()  # alive, not stuck: a refused key or Google away is in the log, the site keeps updating
        if fcm is None:
            # Looked for every minute: putting the key in deploy/secrets is enough, no restart needed.
            try:
                creds, why = load_credentials(cfg.fcm_credentials_file), "no VITRINA_FCM_CREDENTIALS_FILE"
            except Exception as exc:  # unreadable or not a key: said once, push stays off, nothing restarts
                creds, why = None, f"the key file does not open: {type(exc).__name__}: {exc}"
            if creds is None:
                if why != said:
                    log.log(logging.INFO if why.startswith("no ") else logging.ERROR,
                            "push is off (%s): notifications stay in the app", why)
                    said = why
                try:
                    let_go_old(sessions, now_utc())
                except Exception:
                    log.exception("push: marking old notifications failed")
                stopping.wait(60)
                continue
            fcm = Fcm(creds)
            log.info("push is on (Firebase project %s)", creds.project_id)
        try:
            taken, sent = run_once(sessions, fcm, pause=stopping.wait)
            if sent:
                log.info("push: %d sent", sent)
            wait = cfg.push_interval_s
        except Exception as exc:  # the database or Google away, or the key refused: the next look tries again
            if not isinstance(exc, httpx.HTTPError):
                log.exception("push pass failed")
            taken, wait = 0, min(wait * 2, 300)  # a lasting outage is asked about less and less often
        if taken < BATCH:  # a full batch: more are waiting, so on at once
            stopping.wait(wait)
    return 0


if __name__ == "__main__":
    sys.exit(main())
