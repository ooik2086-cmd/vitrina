"""Many people at once on a development server: they browse, search, open listings, favourite, chat and order.

    python3 scripts/load_test.py --db DB_URL --api http://127.0.0.1:8000/api/v1 --users 50 --seconds 30 [--grow 800]

Prints per kind of request: how many, p50/p95/max in ms, and the answers. --grow first copies the listings already
there (run scripts/seed_demo.py before) until there are that many. People sign in by tokens written straight into the
database, so it runs only against a server on this machine and never against a real one.
Measured 2026-10-20 on a 4-core machine sharing its CPU with this script, one server process, 800 listings:
50 people, 25 requests a second, a catalog page in 1.6 s at p50 (it waits for the one process).
"""
import argparse
import hashlib
import random
import secrets
import sys
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

import httpx
from sqlalchemy import create_engine, insert, select
from sqlalchemy.orm import Session

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vitrina_api.models import AuthToken, Listing, ListingSize, Media, PriceChange, User  # noqa: E402

COLORS = ["қара", "ақ", "көк", "қызыл", "сұр", "жасыл"]
WORDS = ["кроссовка", "қара", "көк", "жүгіру", "ақшыл", "kross", "nike"]
ADDRESS = {"recipient_name": "Аза Сапар", "recipient_phone": "+77010000000", "city": "Алматы",
           "address": "Абай даңғылы 10"}


def grow(engine, n: int) -> None:
    """Copies the listings there (with sizes and photos) at other prices and colours until there are n."""
    with Session(engine) as db:
        base = db.scalars(select(Listing)).all()

        def row(obj):
            return {c.key: getattr(obj, c.key) for c in obj.__mapper__.column_attrs if c.key != "id"}
        for i in range(n - len(base)):
            src = base[i % len(base)]
            data = {**row(src), "title": f"{src.title} #{i}", "price_tiyn": random.randrange(800, 9000) * 1000,
                    "color": random.choice(COLORS)}
            lid = db.execute(insert(Listing).values(**data).returning(Listing.id)).scalar()
            for s in src.sizes:
                db.execute(insert(ListingSize).values(**{**row(s), "listing_id": lid, "quantity": random.randint(1, 5)}))
            for m in src.media:
                db.execute(insert(Media).values(**{**row(m), "listing_id": lid}))
            db.execute(insert(PriceChange).values(listing_id=lid, price_tiyn=data["price_tiyn"]))
        db.commit()


def people(engine, n: int) -> list[str]:
    tokens = []
    with Session(engine) as db:
        for i in range(n):
            phone = f"+7702{i:07d}"
            u = db.scalar(select(User).where(User.phone == phone)) or User(phone=phone, display_name=f"Load {i}")
            db.add(u)
            db.flush()
            raw = secrets.token_urlsafe(32)
            db.add(AuthToken(token_hash=hashlib.sha256(raw.encode()).hexdigest(), user_id=u.id,
                             expires_at=datetime.now(timezone.utc) + timedelta(hours=2)))
            tokens.append(raw)
        db.commit()
    return tokens


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--db", required=True)
    p.add_argument("--api", default="http://127.0.0.1:8000/api/v1")
    p.add_argument("--users", type=int, default=50)
    p.add_argument("--seconds", type=float, default=30)
    p.add_argument("--grow", type=int, default=0)
    a = p.parse_args()
    if urlparse(a.api).hostname not in ("127.0.0.1", "localhost"):
        raise SystemExit("only against a server on this machine")
    engine = create_engine(a.db)
    if a.grow:
        grow(engine, a.grow)
    tokens = people(engine, a.users)
    with Session(engine) as db:
        stock = db.execute(select(ListingSize.listing_id, ListingSize.id).join(Listing)
                           .where(Listing.status == "published")).all()
    ids = sorted({lid for lid, _ in stock})
    times, codes, lock = defaultdict(list), defaultdict(lambda: defaultdict(int)), threading.Lock()
    stop = time.monotonic() + a.seconds

    def user(token):
        c = httpx.Client(base_url=a.api, headers={"Authorization": f"Bearer {token}"}, timeout=30)
        rnd = random.Random(token)
        while time.monotonic() < stop:
            r = rnd.random()
            lid = rnd.choice(ids)
            if r < 0.30:
                kind, call = "feed", lambda: c.get("/listings", params={"offset": rnd.choice([0, 20, 40, 200])})
            elif r < 0.45:
                kind, call = "search", lambda: c.get("/listings", params={"q": rnd.choice(WORDS), "sort": "price_asc"})
            elif r < 0.50:
                kind, call = "filter", lambda: c.get("/listings", params={"color": "қара", "size_cm": "27",
                                                                             "max_price_tiyn": 5_000_000})
            elif r < 0.70:
                kind, call = "listing", lambda: c.get(f"/listings/{lid}")
            elif r < 0.75:
                kind, call = "similar", lambda: c.get(f"/listings/{lid}/similar")
            elif r < 0.78:
                kind, call = "suggest", lambda: c.get("/search/suggest", params={"q": rnd.choice(WORDS)[:3]})
            elif r < 0.85:
                kind, call = "favorite", lambda: (c.post if rnd.random() < .6 else c.delete)(f"/favorites/{lid}")
            elif r < 0.88:
                kind, call = "notifications", lambda: c.get("/notifications")
            elif r < 0.91:
                kind, call = "orders", lambda: c.get("/orders")
            elif r < 0.95:
                l, s = rnd.choice(stock)
                kind, call = "order", lambda: c.post("/orders", json={"listing_id": l, "size_id": s, "delivery": ADDRESS},
                                                     headers={"Idempotency-Key": secrets.token_hex(8)})
            else:
                kind, call = "chat", lambda: c.post("/conversations", json={"listing_id": lid})
            t = time.perf_counter()
            try:
                res = call()
                code = res.status_code
                if kind == "order" and code == 201 and rnd.random() < 0.5:
                    c.post(f"/orders/{res.json()['id']}/cancel")
            except Exception as exc:  # noqa: BLE001
                code = type(exc).__name__
            ms = (time.perf_counter() - t) * 1000
            with lock:
                times[kind].append(ms)
                codes[kind][code] += 1

    threads = [threading.Thread(target=user, args=(t,)) for t in tokens]
    start = time.monotonic()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    took = time.monotonic() - start
    total = sum(len(v) for v in times.values())
    print(f"{a.users} people, {took:.0f}s, {total} requests, {total / max(took, 1):.0f}/s")
    for kind in sorted(times, key=lambda k: -sorted(times[k])[int(.95 * len(times[k]))]):
        v = sorted(times[kind])
        q = lambda f: v[min(len(v) - 1, int(f * len(v)))]  # noqa: E731
        print(f"{kind:14} n={len(v):5}  p50={q(.5):6.0f}  p95={q(.95):6.0f}  max={v[-1]:6.0f}  {dict(codes[kind])}")


if __name__ == "__main__":
    main()
