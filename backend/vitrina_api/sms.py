"""Sign-in codes by SMS. One provider for now, Mobizon (mobizon.kz), chosen with VITRINA_SMS_PROVIDER=mobizon and
its key in VITRINA_MOBIZON_API_KEY (from the Mobizon account: API settings). Nothing else in the API knows which
provider it is: auth_routes calls send(phone, text) and gets SmsError when the code did not go out.

Mobizon's HTTP API (https://mobizon.kz/help/api-docs/message): POST {url}/service/message/sendsmsmessage with the
key, output=json and api=v1 in the query and recipient (digits only), text and optionally from (a registered sender
name) in a form body. The answer is {"code": 0, "data": {...}, "message": ""}; any other code is a refusal (a wrong
key, no money left, a bad number), with the reason in message.
"""
from __future__ import annotations

import logging
from typing import Protocol

import httpx

log = logging.getLogger(__name__)
# httpx logs every request's URL at INFO, and Mobizon's URL carries the key: never at INFO, whoever turns it on.
logging.getLogger("httpx").setLevel(logging.WARNING)


class SmsError(Exception):
    """The message did not go out. The text is safe to log: it never holds the key or the code."""


class SmsSender(Protocol):
    def send(self, phone: str, text: str) -> None: ...


class MobizonSender:
    def __init__(self, api_key: str, *, url: str = "https://api.mobizon.kz", sender: str = "",
                 client: httpx.Client | None = None):
        self.api_key, self.url, self.sender = api_key, url.rstrip("/"), sender
        # Short: the person is waiting on the sign-in screen, and a slow provider must not hold an API worker.
        self.client = client or httpx.Client(timeout=httpx.Timeout(10.0, connect=5.0))

    def send(self, phone: str, text: str) -> None:
        body = {"recipient": phone.lstrip("+"), "text": text, **({"from": self.sender} if self.sender else {})}
        r = None
        try:
            r = self.client.post(f"{self.url}/service/message/sendsmsmessage",
                                 params={"output": "json", "api": "v1", "apiKey": self.api_key}, data=body)
            answer = r.json()
        except (httpx.HTTPError, ValueError) as e:
            # Not str(e): an httpx error names the URL, and the URL carries the key.
            raise SmsError(f"mobizon unreachable or not JSON ({type(e).__name__}, HTTP "
                           f"{r.status_code if r is not None else '-'})") from None
        code = answer.get("code") if isinstance(answer, dict) else None
        if code != 0:
            raise SmsError(f"mobizon refused: code {code}, {str(answer.get('message', ''))[:200]}"
                           if isinstance(answer, dict) else "mobizon answered something unexpected")


def make_sender(settings) -> SmsSender | None:
    if settings.sms_provider == "mobizon":
        return MobizonSender(settings.mobizon_api_key, url=settings.mobizon_url, sender=settings.mobizon_from)
    if settings.sms_provider:
        raise RuntimeError(f"VITRINA_SMS_PROVIDER={settings.sms_provider!r} is not known (mobizon, or empty)")
    return None


def otp_text(code: str) -> str:
    """One SMS segment (70 Cyrillic characters at most): the code first, so the phone's notification shows it."""
    return f"{code} - VITRINA коды. Ешкімге айтпаңыз / Никому не сообщайте"
