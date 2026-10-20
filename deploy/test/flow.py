"""Run inside the api container by smoke.sh: a seller lists a shoe on the live stack, through Caddy and HTTPS.

    python flow.py list           a new listing, published; prints its id once the photo worker is done with it
    python flow.py count          how many listings there are
    python flow.py check ID       its share page carries the https address (the proxy headers are trusted)
    python flow.py photo ID       the address of its first photo
"""
import io
import os
import secrets
import sys
import time

import httpx
from PIL import Image, ImageDraw
from sqlalchemy import func, select

from vitrina_api.config import Settings
from vitrina_api.models import Listing, make_session_factory

SITE = f"https://{os.environ['VITRINA_DOMAIN']}"
API = f"{SITE}/api/v1"
sessions = make_session_factory(Settings().database_url, create_schema=False)


def photo(seed: int) -> bytes:
    img = Image.new("RGB", (900, 900), (238, 236, 230))
    ImageDraw.Draw(img).ellipse((150 + seed * 20, 300, 750, 620), fill=(30 + seed * 40, 40, 60))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=90)
    return out.getvalue()


def seller_token() -> str:
    """Signs in as a person does: the API sends the code by SMS (to the stand-in Mobizon in fake_s3.py) and never
    puts it in its answer; the code is read off the SMS."""
    phone = f"+7701{secrets.randbelow(10**7):07d}"
    answer = must(httpx.post(f"{API}/auth/otp", json={"phone": phone}, timeout=30))
    if "dev_code" in answer:
        sys.exit("the sign-in code is in the API's answer: production must send it by SMS only")
    sms = httpx.get(f"https://s3.test/_sms/{phone[1:]}", timeout=30)
    if sms.status_code != 200 or not sms.text[:6].isdigit():
        sys.exit(f"no SMS reached the provider for {phone}: {sms.status_code} {sms.text[:100]}")
    return must(httpx.post(f"{API}/auth/verify", json={"phone": phone, "code": sms.text[:6]}, timeout=30))["token"]


def must(r: httpx.Response, status: int = 200) -> dict:
    if r.status_code != status:
        sys.exit(f"{r.request.method} {r.request.url}: {r.status_code} {r.text[:300]}")
    return r.json()


def new_listing() -> None:
    c = httpx.Client(headers={"Authorization": f"Bearer {seller_token()}"}, timeout=60)
    must(c.post(f"{API}/me/seller", json={"shop_name": "Сынақ дүкені", "city": "Алматы"}))
    photos = []
    for seed, angle in enumerate(("front", "outer", "inner", "back")):
        url = must(c.post(f"{API}/media", files={"file": ("p.jpg", photo(seed), "image/jpeg")}), 201)["url"]
        if not url.startswith(os.environ["VITRINA_PUBLIC_MEDIA_URL"]):
            sys.exit(f"photo stored at {url}, not at VITRINA_PUBLIC_MEDIA_URL")
        if httpx.get(url, timeout=30).status_code != 200:  # what a buyer's phone does
            sys.exit(f"the photo is not readable at its public address {url}")
        photos.append({"url": url, "angle": angle})
    lid = must(c.post(f"{API}/listings", json={
        "title": "Сынақ кроссовкасы", "category": "sneakers", "brand": "Сынақ", "color": "қара",
        "condition": "new_with_box", "price_tiyn": 2_000_000,
        "sizes": [{"label": "42", "insole_cm": "27", "quantity": 1}], "photos": photos}), 201)["id"]
    must(c.post(f"{API}/listings/{lid}/publish"))
    for _ in range(120):  # the photo worker cuts the four photos out
        mine = next(i for i in must(c.get(f"{API}/me/listings"))["items"] if i["id"] == lid)
        if not mine["photos_pending"] and all(m["thumb_url"] for m in mine["media"]):
            break
        time.sleep(3)
    else:
        sys.exit(f"listing {lid}: the photo worker did not finish its photos")
    print(lid)


def check(lid: str) -> None:
    page = httpx.get(f"{SITE}/l/{lid}", timeout=30)
    if page.status_code != 200 or f'content="{SITE}/l/{lid}"' not in page.text:
        sys.exit(f"share page of {lid}: {page.status_code}, no https address in it")
    print("share page ok")


if __name__ == "__main__":
    if sys.argv[1] == "list":
        new_listing()
    elif sys.argv[1] == "photo":
        print(httpx.get(f"{API}/listings/{sys.argv[2]}", timeout=30).json()["media"][0]["original_url"])
    elif sys.argv[1] == "count":
        with sessions() as db:
            print(db.scalar(select(func.count(Listing.id))))
    else:
        check(sys.argv[2])
