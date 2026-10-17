"""Fill a running development server with demo listings through the public API.

    python3 scripts/seed_demo.py --frames ./demo-frames

--frames is a local folder with an ordered photo sequence taken around a shoe (any .jpg/.png names, sorted).
Photos go through the normal upload endpoint, so they are cleaned and stored like a seller's.
Needs VITRINA_DEBUG_OTP=1 on the server, because sign-in reads the code from the response.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import httpx


def login(c: httpx.Client, phone: str) -> dict:
    code = c.post("/auth/otp", json={"phone": phone}).raise_for_status().json().get("dev_code")
    if not code:
        raise SystemExit("server does not return dev_code; set VITRINA_DEBUG_OTP=1 for seeding")
    token = c.post("/auth/verify", json={"phone": phone, "code": code}).raise_for_status().json()["token"]
    return {"Authorization": f"Bearer {token}"}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000/api/v1")
    p.add_argument("--frames", required=True, type=Path, help="folder with the ordered frame photos")
    args = p.parse_args()
    files = sorted(f for f in args.frames.iterdir() if f.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp"))
    if len(files) < 8:
        raise SystemExit("need at least 8 frames")

    with httpx.Client(base_url=args.api, timeout=10) as c:
        seller = login(c, "+77010000001")
        c.post("/me/seller", json={"shop_name": "Qadam Store", "city": "Алматы"}, headers=seller)
        urls = [c.post("/media", files={"file": (f.name, f.read_bytes())}, headers=seller).raise_for_status().json()["url"]
                for f in files]
        q = len(urls) // 4
        frames = [{"url": u, "angle": "frame"} for u in urls]
        shots = [{"url": urls[i * q], "angle": a} for i, a in enumerate(("outer", "front", "inner", "back"))]
        demos = [
            {"title": "Qadam Runner, құмды түсті", "category": "sneakers", "brand": "Qadam", "color": "құм",
             "condition": "new_with_box", "price_tiyn": 3_490_000, "delivery_price_tiyn": 150_000,
             "showcase_style": "clean", "description": "Күнделікті киюге арналған жеңіл кроссовка.",
             "sizes": [{"label": "41", "insole_cm": "26,5", "quantity": 2},
                       {"label": "42", "insole_cm": "27", "quantity": 1},
                       {"label": "43", "insole_cm": "27,5", "quantity": 0}],
             "photos": shots + frames},
            {"title": "Qadam Runner, киілген", "category": "sneakers", "brand": "Qadam", "color": "құм",
             "condition": "used_good", "defects": "Сол аяқтың тұмсығында 1 см сызат, суретте көрсетілген.",
             "price_tiyn": 1_890_000, "showcase_style": "premium",
             "sizes": [{"label": "42", "insole_cm": "27", "quantity": 1}],
             "photos": shots + [{"url": urls[q // 2], "angle": "defect"}] + frames},
        ]
        for body in demos:
            r = c.post("/listings", json=body, headers=seller).raise_for_status().json()
            c.post(f"/listings/{r['id']}/publish", headers=seller).raise_for_status()
            print("published", r["id"], body["title"])


if __name__ == "__main__":
    main()
