"""Fill a running development server with demo listings through the public API.

    python3 scripts/seed_demo.py                      # uses demo/frames next to this script
    python3 scripts/seed_demo.py --api http://127.0.0.1:8000/api/v1

Each folder in demo/frames is one shoe: an ordered 360° sequence fNN.jpg plus top, sole and detail views
(see demo/ATTRIBUTION.md for the source).
Photos go through the normal upload endpoint, so they are cleaned and stored like a seller's.
Needs VITRINA_DEBUG_OTP=1 on the server, because sign-in reads the code from the response.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import httpx

DEMO = Path(__file__).resolve().parent.parent / "demo" / "frames"
SIZES = [("39", "25"), ("40", "25,5"), ("41", "26,5"), ("42", "27"), ("43", "27,5"), ("44", "28,5")]

# Listings per frame folder. Facts stay separate: condition, defects and price are the seller's claims.
LISTINGS = {
    "street": [
        {"title": "Жеңіл жүгіру кроссовкасы, қара", "color": "қара", "condition": "new_with_box",
         "price_tiyn": 3_290_000, "delivery_price_tiyn": 150_000, "showcase_style": "premium",
         "description": "Тор матадан жеңіл кроссовка, көбік табан. Қорабы мен жапсырмасы бар.",
         "facts": {"upper": "mesh", "lining": "textile", "sole": "eva", "season": "demi", "country": "TR"}},
        {"title": "Жеңіл кроссовка, қара, киілген", "color": "қара", "condition": "used_good",
         "defects": "Оң аяқтың табанында аздап сарғаю, тор мата бүтін.", "price_tiyn": 1_490_000,
         "showcase_style": "clean", "sizes": [("42", "27", 1)],
         "facts": {"upper": "mesh", "lining": "textile", "sole": "eva", "season": "demi"}},
    ],
    "midnight": [
        {"title": "Жеңіл жүгіру кроссовкасы, көк", "color": "көк", "condition": "new_no_box",
         "price_tiyn": 2_990_000, "delivery_price_tiyn": 0, "showcase_style": "dynamic",
         "description": "Күнделікті және жүгіруге. Қорабы жоқ, киілмеген.",
         "facts": {"upper": "mesh", "lining": "textile", "sole": "eva", "season": "summer", "country": "TR"}},
    ],
    "beach": [
        {"title": "Жеңіл кроссовка, ақшыл қызғылт", "color": "қызғылт", "condition": "unworn_stored",
         "price_tiyn": 2_490_000, "delivery_price_tiyn": 120_000, "showcase_style": "clean",
         "description": "Бір рет өлшеп көрілген, сақтауда тұрған.",
         "facts": {"upper": "textile", "lining": "textile", "sole": "eva", "season": "summer", "country": "CN"}},
    ],
}


def login(c: httpx.Client, phone: str) -> dict:
    code = c.post("/auth/otp", json={"phone": phone}).raise_for_status().json().get("dev_code")
    if not code:
        raise SystemExit("server does not return dev_code; set VITRINA_DEBUG_OTP=1 for seeding")
    token = c.post("/auth/verify", json={"phone": phone, "code": code}).raise_for_status().json()["token"]
    return {"Authorization": f"Bearer {token}"}


def upload(c: httpx.Client, auth: dict, path: Path, detail: bool = False) -> str:
    return c.post("/media", params={"detail": "true"} if detail else None, files={"file": (path.name, path.read_bytes())},
                  headers=auth).raise_for_status().json()["url"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000/api/v1")
    p.add_argument("--frames", type=Path, default=DEMO, help="folder with one sub-folder of ordered frames per shoe")
    args = p.parse_args()

    with httpx.Client(base_url=args.api, timeout=30) as c:
        seller = login(c, "+77010000001")
        c.post("/me/seller", json={"shop_name": "Qadam Store", "city": "Алматы"}, headers=seller)
        for folder, listings in LISTINGS.items():
            files = sorted((args.frames / folder).glob("f*.jpg"))
            if len(files) < 8:
                raise SystemExit(f"{folder}: need at least 8 frames")
            urls = [upload(c, seller, f) for f in files]
            q = len(urls) // 4
            # The four required angles are frames from the same turn: outer side, toe, inner side, heel.
            shots = [{"url": urls[(i * q) % len(urls)], "angle": a}
                     for i, a in enumerate(("outer", "front", "inner", "back"))]
            frames = [{"url": u, "angle": "frame"} for u in urls]
            # The showcase's stops after the turn, rendered from the same scan (tools/demo-frames).
            stops = [{"url": upload(c, seller, args.frames / folder / f"{a}.jpg", detail=True), "angle": a}
                     for a in ("top", "sole", "detail") if (args.frames / folder / f"{a}.jpg").exists()]
            for spec in listings:
                spec = dict(spec)
                sizes = spec.pop("sizes", [(label, cm, 2) for label, cm in SIZES])
                body = {"category": "sneakers", **spec,
                        "sizes": [{"label": s, "insole_cm": cm, "quantity": n} for s, cm, n in sizes],
                        "photos": shots + stops
                                  + ([{"url": urls[q // 2], "angle": "defect"}] if spec.get("defects") else [])
                                  + frames}
                r = c.post("/listings", json=body, headers=seller).raise_for_status().json()
                c.post(f"/listings/{r['id']}/publish", headers=seller).raise_for_status()
                print("published", r["id"], body["title"])


if __name__ == "__main__":
    main()
