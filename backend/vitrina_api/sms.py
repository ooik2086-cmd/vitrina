"""Sign-in codes by SMS. One provider for now, Mobizon (mobizon.kz), chosen with VITRINA_SMS_PROVIDER=mobizon and
its key in VITRINA_MOBIZON_API_KEY (from the Mobizon account: API settings). Nothing else in the API knows which
provider it is: auth_routes calls send(phone, text) and gets SmsError when the code did not go out.

Mobizon's HTTP API (https://mobizon.kz/help/api-docs/message): POST {url}/service/message/sendsmsmessage with the
key, output=json and api=v1 in the query and recipient (digits only), text and optionally from (a registered sender
name) in a form body. The answer is {"code": 0, "data": {...}, "message": ""}; any other code is a refusal (a wrong
key, no money left, a bad number), with the reason in message.

A failure is either certain (nothing went out: no connection, or Mobizon said no) or not (the request left but the
answer was lost or unreadable: the SMS may still arrive and be billed). SmsError.maybe_sent tells them apart.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Protocol

import httpx

log = logging.getLogger("vitrina.sms")
# httpx logs every request's URL at INFO, and Mobizon's URL carries the key: never at INFO, whoever turns it on.
logging.getLogger("httpx").setLevel(logging.WARNING)


class SmsError(Exception):
    """The message did not go out, or (maybe_sent) it is not known whether it did. The text is safe to log: it never
    holds the key or the code."""

    def __init__(self, text: str, *, maybe_sent: bool = False):
        super().__init__(text)
        self.maybe_sent = maybe_sent


class SmsSender(Protocol):
    def send(self, phone: str, text: str) -> None: ...


class MobizonSender:
    # After this many certain failures in a row, sends fail at once for PAUSE_S seconds: while Mobizon is down or
    # the balance is empty, sign-in taps answer at once instead of each holding an API thread up to the timeout.
    FAILURES_BEFORE_PAUSE, PAUSE_S = 3, 30.0

    def __init__(self, api_key: str, *, url: str = "https://api.mobizon.kz", sender: str = "",
                 client: httpx.Client | None = None):
        self.api_key, self.url, self.sender = api_key, url.rstrip("/"), sender
        # Short: the person is waiting on the sign-in screen, and a slow provider must not hold an API worker.
        self.client = client or httpx.Client(timeout=httpx.Timeout(6.0, connect=3.0))
        self._lock = threading.Lock()
        self._failures, self._paused_until = 0, 0.0

    def send(self, phone: str, text: str) -> None:
        with self._lock:
            if time.monotonic() < self._paused_until:
                raise SmsError(f"not tried: {self._failures} failures in a row, paused {self.PAUSE_S:.0f} s")
        try:
            self._send(phone, text)
        except SmsError as e:
            with self._lock:
                if not e.maybe_sent:
                    self._failures += 1
                    if self._failures >= self.FAILURES_BEFORE_PAUSE:
                        self._paused_until = time.monotonic() + self.PAUSE_S
            raise
        with self._lock:
            self._failures = 0

    def _send(self, phone: str, text: str) -> None:
        body = {"recipient": phone.lstrip("+"), "text": text, **({"from": self.sender} if self.sender else {})}
        r = None
        try:
            r = self.client.post(f"{self.url}/service/message/sendsmsmessage",
                                 params={"output": "json", "api": "v1", "apiKey": self.api_key}, data=body)
            answer = r.json()
        except (httpx.HTTPError, ValueError) as e:
            # Not str(e): an httpx error names the URL, and the URL carries the key. Only a failed connection is
            # sure to have sent nothing; after that the request may have reached Mobizon.
            raise SmsError(f"mobizon unreachable or not JSON ({type(e).__name__}, HTTP "
                           f"{r.status_code if r is not None else '-'})",
                           maybe_sent=not isinstance(e, (httpx.ConnectError, httpx.ConnectTimeout))) from None
        code = answer.get("code") if isinstance(answer, dict) else None
        if code != 0:
            # 100 is Mobizon's "accepted, done in the background"; not documented for this call, so not a "no".
            raise SmsError(f"mobizon refused: code {code}, {str(answer.get('message', ''))[:200]}"
                           if isinstance(answer, dict) else "mobizon answered something unexpected",
                           maybe_sent=code == 100 or not isinstance(answer, dict))


def make_sender(settings) -> SmsSender | None:
    if settings.sms_provider == "mobizon":
        return MobizonSender(settings.mobizon_api_key, url=settings.mobizon_url, sender=settings.mobizon_from)
    if settings.sms_provider:
        raise RuntimeError(f"VITRINA_SMS_PROVIDER={settings.sms_provider!r} is not known (mobizon, or empty)")
    return None


def otp_text(code: str) -> str:
    """One SMS segment (70 Cyrillic characters at most): the code first, so the phone's notification shows it."""
    return f"{code} - VITRINA коды. Ешкімге айтпаңыз / Никому не сообщайте"
