"""Public pages for shared links: a listing at /l/{id}, a whole shop at /s/{seller_id}.

Messengers (WhatsApp, Telegram, Instagram DMs) read the Open Graph tags and show the shoe's photo, title and
price as a preview. Someone without the app can turn the shoe on the page itself, from the seller's real 360°
frames, and open it in the app with one tap. Only published listings are shown; no seller phone, ever.
"""
from __future__ import annotations

import html
import json
from datetime import timedelta, timezone

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import promo
from .deps import get_db, now_utc
from .models import Listing, Review, User
from .serializers import cover_frame

router = APIRouter()

LANGS = ("kk", "ru", "en")
CONDITIONS = {
    "new_with_box": ("Жаңа, қорабымен", "Новые, с коробкой", "New, with box"),
    "new_no_box": ("Жаңа, қорабсыз", "Новые, без коробки", "New, no box"),
    "unworn_stored": ("Киілмеген, сақталған", "Не ношенные, хранились", "Unworn, stored"),
    "used_excellent": ("Киілген, өте жақсы", "Ношенные, отличное состояние", "Worn, excellent"),
    "used_good": ("Киілген, жақсы", "Ношенные, хорошее состояние", "Worn, good"),
    "defective": ("Ақауы бар", "Есть дефекты", "Has defects"),
}
TEXT = {
    "kk": {"open": "Қосымшада ашу", "drag": "Айналдыру үшін сүйреңіз", "sizes": "Өлшемдер", "delivery": "Жеткізу",
           "free": "тегін", "protected": "Ақша сатып алушы тауарды алып, растағанша сақталады.",
           "gone": "Бұл тауар енді сатылымда жоқ.", "seller": "Сатушы", "open_shop": "Дүкенді қосымшада ашу",
           "shop_gone": "Бұл дүкен табылмады.", "empty": "Дүкенде қазір тауар жоқ.", "goods": "тауар",
           "reviews": "пікір", "away": "Сатушы демалыста, тапсырыстар кейін қабылданады."},
    "ru": {"open": "Открыть в приложении", "drag": "Проведите, чтобы повернуть", "sizes": "Размеры",
           "delivery": "Доставка", "free": "бесплатно",
           "protected": "Деньги хранятся, пока покупатель не получит товар и не подтвердит это.",
           "gone": "Этот товар больше не продаётся.", "seller": "Продавец", "open_shop": "Открыть магазин в приложении",
           "shop_gone": "Этот магазин не найден.", "empty": "Сейчас в магазине нет товаров.", "goods": "товаров",
           "reviews": "отзывов", "away": "Продавец в отпуске, заказы примет позже."},
    "en": {"open": "Open in the app", "drag": "Drag to turn", "sizes": "Sizes", "delivery": "Delivery", "free": "free",
           "protected": "The money is held until the buyer receives the item and confirms it.",
           "gone": "This listing is no longer on sale.", "seller": "Seller", "open_shop": "Open the shop in the app",
           "shop_gone": "This shop wasn't found.", "empty": "The shop has nothing on sale right now.",
           "goods": "items", "reviews": "reviews", "away": "The seller is away and will take orders later."},
}
ALMATY = timezone(timedelta(hours=5))
SHOWCASE = ("front", "outer", "inner", "back", "top")
BACKDROPS = {
    "premium": "radial-gradient(circle at 50% 45%, #3a3a40, #111114 75%)",
    "dynamic": "linear-gradient(135deg, #ffe3d3, #d9e6ff)",
}


def pick_lang(request: Request) -> str:
    wanted = request.query_params.get("lang") or request.headers.get("accept-language", "")
    wanted = wanted.lower()
    return next((code for code in ("ru", "en") if wanted.startswith(code)), "kk")


def page(title: str, body: str, *, lang: str, meta: str = "", status: int = 200) -> HTMLResponse:
    return HTMLResponse(f"""<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>{meta}
<style>
:root{{--ink:#0e0e10;--accent:#ff5a36;--studio:#f3f2ef;--muted:#6b6b72}}
*{{box-sizing:border-box}}body{{margin:0;font-family:Inter,system-ui,-apple-system,sans-serif;background:var(--studio);color:var(--ink)}}
main{{max-width:520px;margin:0 auto;padding:0 0 32px}}
.brand{{letter-spacing:.35em;font-weight:700;font-size:13px;padding:18px 20px}}
.stage{{position:relative;aspect-ratio:1;touch-action:pan-y;cursor:grab;user-select:none}}
.stage img{{position:absolute;inset:6%;width:88%;height:88%;object-fit:contain;-webkit-user-drag:none}}
.hint{{position:absolute;left:50%;bottom:14px;transform:translateX(-50%);background:#fff;border-radius:99px;
padding:6px 14px;font-size:13px;white-space:nowrap;box-shadow:0 2px 10px rgba(0,0,0,.08)}}
.info{{padding:20px}}h1{{font-size:26px;line-height:1.2;margin:0 0 8px}}
.price{{font-size:30px;font-weight:800;margin:4px 0}}.muted{{color:var(--muted)}}
.chips{{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0 18px}}
.chip{{border:1px solid #ddd;background:#fff;border-radius:12px;padding:8px 12px;font-size:14px}}
.chip.off{{opacity:.45;text-decoration:line-through}}
.cta{{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;
padding:16px;border-radius:16px;font-size:17px}}
.note{{font-size:13px;margin-top:12px}}
.grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;padding:0 20px 20px}}
.card{{color:inherit;text-decoration:none;background:#fff;border-radius:16px;overflow:hidden}}
.card img{{width:100%;aspect-ratio:1;object-fit:contain;background:var(--studio);display:block}}
.card div{{padding:8px 10px 12px;font-size:14px}}.card b{{display:block;font-size:16px;margin-top:2px}}
.was{{color:var(--muted);text-decoration:line-through;font-size:13px;margin-left:6px;font-weight:400}}
.about{{white-space:pre-line;line-height:1.45;margin:12px 0 0}}
</style></head><body><main><div class="brand">VITRINA</div>{body}</main></body></html>""", status_code=status)


@router.get("/l/{listing_id}", response_class=HTMLResponse, include_in_schema=False)
def shared_listing(listing_id: int, request: Request, db: Session = Depends(get_db)):
    lang = pick_lang(request)
    t = TEXT[lang]
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status != "published":
        return page("VITRINA", f'<div class="info"><h1>{t["gone"]}</h1></div>', lang=lang, status=404)
    seller = db.get(User, listing.seller_id)
    media = sorted(listing.media, key=lambda m: m.position)
    showcase = [m for m in media if m.angle in SHOWCASE]
    # Each shot: the small copy shown while turning, and the full photo shown at rest.
    shots = turn_shots(listing, media) or [(m.processed_url or m.original_url,) * 2 for m in showcase]
    # Previews use the original JPEG: some messengers do not show WebP.
    cover = next((m.original_url for m in showcase), media[0].original_url if media else None)
    price = promo.format_tenge(listing.price_tiyn)
    condition = CONDITIONS.get(listing.condition, (listing.condition,) * 3)[LANGS.index(lang)]
    city = seller.city if seller else None
    description = " · ".join(x for x in (condition, seller.shop_name if seller else None, city) if x)
    url = str(request.url.replace(query=""))
    esc = html.escape
    meta = "".join(f'\n<meta property="{k}" content="{esc(v)}">' for k, v in (
        ("og:type", "product"), ("og:site_name", "VITRINA"), ("og:title", f"{listing.title} · {price}"),
        ("og:description", description), ("og:url", url), *((("og:image", cover),) if cover else ()),
        ("product:price:amount", str(listing.price_tiyn // 100)), ("product:price:currency", "KZT")))
    meta += '\n<meta name="twitter:card" content="summary_large_image">'
    sizes = "".join(f'<span class="chip{"" if s.quantity > 0 else " off"}">{esc(s.label)} · '
                    f'{s.insole_mm // 10},{s.insole_mm % 10} см</span>' for s in listing.sizes)
    delivery = (t["free"] if listing.delivery_price_tiyn == 0 else promo.format_tenge(listing.delivery_price_tiyn))
    backdrop = BACKDROPS.get(listing.showcase_style, "var(--studio)")
    spin_js = ""
    if len(shots) > 1:
        # Inside <script> a "</script>" in any string would end the block, so "<" never appears raw.
        small_js = json.dumps([small for small, _ in shots]).replace("<", "\\u003c")
        full_js = json.dumps([full for _, full in shots]).replace("<", "\\u003c")
        spin_js = f"""<script>
(() => {{
  // Small copies while the shoe turns, the full photo once it rests; one slow turn on arrival, unless the phone
  // asks for less motion. The small copies load one after another, so the first ones come first on slow data.
  const small = {small_js}, full = {full_js}, img = document.getElementById('shot'), stage = document.getElementById('stage');
  const n = small.length, calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ready = new Set();
  (function load(i) {{ if (i >= n) return; const p = new Image();
    p.onload = p.onerror = () => {{ if (p.complete && p.naturalWidth) ready.add(i); load(i + 1); }}; p.src = small[i]; }})(0);
  let k = 0, x0 = null, k0 = 0, rest = null, auto = null;
  const settle = () => {{ clearTimeout(rest); rest = setTimeout(() => {{ img.src = full[k]; }}, 250); }};
  const show = m => {{ m = ((m % n) + n) % n; if (m === k) return; k = m; if (ready.has(k) || !auto) img.src = small[k]; settle(); }};
  const stop = () => {{ clearInterval(auto); auto = null; }};
  stage.addEventListener('pointerdown', e => {{ stop(); x0 = e.clientX; k0 = k; stage.setPointerCapture(e.pointerId); }});
  stage.addEventListener('pointermove', e => {{ if (x0 !== null) show(k0 + Math.round((e.clientX - x0) * n / (stage.clientWidth * 1.5))); }});
  stage.addEventListener('pointerup', () => {{ x0 = null; }});
  stage.addEventListener('pointercancel', () => {{ x0 = null; }});
  if (!calm) {{ let step = 0; auto = setInterval(() => {{ if (!ready.has((k + 1) % n)) return; show(k + 1);
    if (++step >= n) {{ stop(); settle(); }} }}, Math.max(40, Math.round(2400 / n))); }}
}})();
</script>"""
    stage = (f'<div class="stage" id="stage" style="background:{backdrop}">'
             f'<img id="shot" alt="{esc(listing.title)}" src="{esc(shots[0][1])}" draggable="false">'
             + (f'<div class="hint">↔ {t["drag"]}</div>' if len(shots) > 1 else "") + "</div>") if shots else ""
    body = f"""{stage}
<div class="info">
<h1>{esc(listing.title)}</h1>
<div class="price">{esc(price)}</div>
<div class="muted">{esc(description)} · {t["delivery"]} {esc(delivery)}</div>
{f'<p><a class="muted" href="/s/{seller.id}">{t["seller"]}: {esc(seller.shop_name or "")} →</a></p>' if seller else ""}
<h3>{t["sizes"]}</h3><div class="chips">{sizes}</div>
<a class="cta" href="vitrina://open/listing/{listing.id}">{t["open"]}</a>
<p class="note muted">{t["protected"]}</p>
</div>{spin_js}"""
    return page(f"{listing.title} · {price} · VITRINA", body, lang=lang, meta=meta)


def turn_shots(listing: Listing, media: list) -> list[tuple[str, str]]:
    """The 360° turn as the app shows it: one turn, from the frame matching the cover, cut-outs only when every
    frame has one (else the photos as taken). Each shot is (small copy, full photo); the small copy is the full
    photo when there is none. A scan carries on over the top and under the sole after its turn: only the turn."""
    frames = [m for m in media if m.angle == "frame"]
    if not frames:
        return []
    at = [next((i for i, f in enumerate(frames) if f.original_url == m.original_url), -1)
          for m in (next((m for m in media if m.angle == angle), None) for angle in ("top", "sole", "detail")) if m]
    if at and at[0] > 0 and all(b > a for a, b in zip(at, at[1:])):
        frames = frames[:at[0]]  # a scan: its turn starts where the camera did
    else:
        start = next((i for i, f in enumerate(frames) if f.original_url == cover_frame(listing)), 0)
        frames = frames[start:] + frames[:start]
    frames = next((frames[:k] for k in range(1, len(frames)) if frames[k].original_url == frames[0].original_url),
                  frames)
    cut = all(f.processed_url for f in frames)
    return [(f.thumb_url if f.thumb_url and (cut or not f.processed_url) else full, full)
            for f in frames for full in [f.processed_url if cut else f.original_url]]


def cover_url(listing: Listing) -> str | None:
    media = sorted(listing.media, key=lambda m: m.position)
    showcase = [m for m in media if m.angle in SHOWCASE]
    return next((m.original_url for m in showcase), media[0].original_url if media else None)


@router.get("/s/{seller_id}", response_class=HTMLResponse, include_in_schema=False)
def shared_shop(seller_id: int, request: Request, db: Session = Depends(get_db)):
    """A seller's whole shop as one link for an Instagram bio or a WhatsApp status: what is on sale now, the
    platform's own rating, and the way into the app. Each card opens the listing's own shared page."""
    lang = pick_lang(request)
    t = TEXT[lang]
    seller = db.get(User, seller_id)
    if seller is None or not seller.is_seller or seller.is_blocked:
        return page("VITRINA", f'<div class="info"><h1>{t["shop_gone"]}</h1></div>', lang=lang, status=404)
    listings = db.scalars(select(Listing).where(Listing.seller_id == seller.id, Listing.status == "published")
                          .order_by(Listing.id.desc()).limit(60)).all()
    avg, count = db.execute(select(func.avg(Review.rating), func.count(Review.id))
                            .where(Review.seller_id == seller.id)).one()
    esc = html.escape
    name = seller.shop_name or "VITRINA"
    facts = [x for x in (
        seller.city, f"★ {float(avg):.1f} · {count} {t['reviews']}" if count else None,
        f"{len(listings)} {t['goods']}") if x]
    description = " · ".join(facts)
    cover = next((c for c in map(cover_url, listings) if c), None)
    url = str(request.url.replace(query=""))
    meta = "".join(f'\n<meta property="{k}" content="{esc(v)}">' for k, v in (
        ("og:type", "website"), ("og:site_name", "VITRINA"), ("og:title", name),
        ("og:description", seller.shop_about or description), ("og:url", url),
        *((("og:image", cover),) if cover else ())))
    meta += '\n<meta name="twitter:card" content="summary_large_image">'
    cards = "".join(
        f'<a class="card" href="/l/{l.id}">'
        + (f'<img loading="lazy" alt="{esc(l.title)}" src="{esc(c)}">' if (c := cover_url(l)) else "")
        + f'<div>{esc(l.title)}<b>{esc(promo.format_tenge(l.price_tiyn))}'
        + (f'<span class="was">{esc(promo.format_tenge(l.was_price_tiyn))}</span>' if l.was_price_tiyn else "")
        + "</b></div></a>" for l in listings)
    away = seller.away_until is not None and seller.away_until >= now_utc().astimezone(ALMATY).date()
    body = f"""<div class="info">
<h1>{esc(name)}</h1>
<div class="muted">{esc(description)}</div>
{f'<p class="about">{esc(seller.shop_about)}</p>' if seller.shop_about else ""}
{f'<p class="note muted">{t["away"]}</p>' if away else ""}
</div>
{f'<div class="grid">{cards}</div>' if listings else f'<p class="info muted">{t["empty"]}</p>'}
<div class="info"><a class="cta" href="vitrina://open/shop/{seller.id}">{t["open_shop"]}</a>
<p class="note muted">{t["protected"]}</p></div>"""
    return page(f"{name} · VITRINA", body, lang=lang, meta=meta)
