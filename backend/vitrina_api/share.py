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
from .serializers import cover_frame, one_turn

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
           "reviews": "пікір", "away": "Сатушы демалыста, тапсырыстар кейін қабылданады.",
           "keys": "Бұру үшін солға не оңға көрсеткі пернесін басыңыз."},
    "ru": {"open": "Открыть в приложении", "drag": "Проведите, чтобы повернуть", "sizes": "Размеры",
           "delivery": "Доставка", "free": "бесплатно",
           "protected": "Деньги хранятся, пока покупатель не получит товар и не подтвердит это.",
           "gone": "Этот товар больше не продаётся.", "seller": "Продавец", "open_shop": "Открыть магазин в приложении",
           "shop_gone": "Этот магазин не найден.", "empty": "Сейчас в магазине нет товаров.", "goods": "товаров",
           "reviews": "отзывов", "away": "Продавец в отпуске, заказы примет позже.",
           "keys": "Чтобы повернуть, нажимайте стрелки влево и вправо."},
    "en": {"open": "Open in the app", "drag": "Drag to turn", "sizes": "Sizes", "delivery": "Delivery", "free": "free",
           "protected": "The money is held until the buyer receives the item and confirms it.",
           "gone": "This listing is no longer on sale.", "seller": "Seller", "open_shop": "Open the shop in the app",
           "shop_gone": "This shop wasn't found.", "empty": "The shop has nothing on sale right now.",
           "goods": "items", "reviews": "reviews", "away": "The seller is away and will take orders later.",
           "keys": "Use the left and right arrow keys to turn it."},
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
.stage{{position:relative;aspect-ratio:1;touch-action:pan-y pinch-zoom;cursor:grab;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none}}
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
    shots, cut = turn_shots(listing, media)
    shots = shots or [(m.processed_url or m.original_url,) * 2 for m in showcase]
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
    backdrop = (SCENES[listing.backdrop] if cut and listing.backdrop in SCENES
                else BACKDROPS.get(listing.showcase_style, "var(--studio)"))
    spin_js = ""
    if len(shots) > 1:
        # Inside <script> a "</script>" in any string would end the block, so "<" never appears raw.
        small_js = json.dumps([small for small, _ in shots]).replace("<", "\\u003c")
        full_js = json.dumps([full for _, full in shots]).replace("<", "\\u003c")
        # Only real small copies are fetched ahead and turned through on arrival: full photos would cost megabytes
        # of someone's mobile data before they touched anything.
        light = all(small != full for small, full in shots)
        spin_js = f"""<script>
(() => {{
  // Small copies while the shoe turns, the full photo once it rests. One slow turn on arrival, unless the phone
  // asks for less motion or data saving. Dragging right turns the shoe to the right, as in the app.
  const small = {small_js}, full = {full_js}, img = document.getElementById('shot'), stage = document.getElementById('stage');
  const n = small.length, light = {"true" if light else "false"};
  const net = navigator.connection || {{}}, calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ready = new Set(), done = new Set();
  let next = 0, k = 0, rest = null, auto = null, finger = null, x0 = 0, k0 = 0, moved = false;
  // A few at a time, in turn order, so the first frames come first.
  const load = () => {{ if (next >= n) return; const i = next++, p = new Image();
    p.onload = p.onerror = () => {{ if (p.naturalWidth) ready.add(i); done.add(i); load(); }}; p.src = small[i]; }};
  const fetchAll = () => {{ if (next === 0) for (let w = 0; w < 3; w++) load(); }};
  const label = () => stage.setAttribute('aria-valuenow', k + 1);
  const settle = () => {{ clearTimeout(rest); rest = setTimeout(() => {{ img.src = full[k]; }}, 250); }};
  const show = m => {{ m = ((m % n) + n) % n; if (m === k) return; k = m; label();
    if (ready.has(k) || !light) img.src = small[k]; if (!auto) settle(); }};
  const stop = () => {{ if (auto) {{ clearInterval(auto); auto = null; settle(); }} }};
  stage.addEventListener('pointerdown', e => {{ if (finger !== null) return; fetchAll();
    finger = e.pointerId; x0 = e.clientX; k0 = k; moved = false; }});
  stage.addEventListener('pointermove', e => {{ if (e.pointerId !== finger) return;
    // A vertical scroll that starts on the shoe leaves the turn alone; a sideways drag takes it over.
    if (!moved && Math.abs(e.clientX - x0) < 8) return;
    if (!moved) {{ moved = true; stop(); stage.setPointerCapture(e.pointerId); x0 = e.clientX; k0 = k; }}
    show(k0 - Math.round((e.clientX - x0) * n / (stage.clientWidth * 1.5))); }});
  const lift = e => {{ if (e.pointerId === finger) finger = null; }};
  stage.addEventListener('pointerup', lift);
  stage.addEventListener('pointercancel', lift);
  stage.addEventListener('keydown', e => {{ const d = {{ArrowLeft: 1, ArrowRight: -1}}[e.key];
    if (d) {{ e.preventDefault(); stop(); fetchAll(); show(k + d); }} }});
  if (light && !calm && !net.saveData && !/2g/.test(net.effectiveType || '')) {{
    fetchAll();
    // Waits for each small copy, steps over one that fails, and gives up rather than turning for ever.
    let step = 0; const until = Date.now() + 8000;
    auto = setInterval(() => {{ const j = (k + 1) % n; if (Date.now() > until) {{ stop(); return; }}
      if (!done.has(j)) return; if (ready.has(j)) show(j); else {{ k = j; label(); }}
      if (++step >= n) stop(); }}, Math.max(40, Math.round(2400 / n)));
  }}
}})();
</script>"""
    stage = (f'<div class="stage" id="stage" style="background:{backdrop}"'
             + (f' tabindex="0" role="slider" aria-label="{esc(listing.title)}: 360°. {t["keys"]}" aria-valuemin="1"'
                f' aria-valuemax="{len(shots)}" aria-valuenow="1"' if len(shots) > 1 else "") + ">"
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


def turn_shots(listing: Listing, media: list) -> tuple[list[tuple[str, str]], bool]:
    """The 360° turn as the app shows it (ShowcasePlan.of): one turn, from the frame matching the cover, cut-outs
    only when every frame has one (else the photos as taken). Each shot is (small copy, full photo); the small copy
    is the full photo when there is none. A scan carries on over the top and under the sole after its turn: only
    the turn, from where the camera started. Also says whether the turn is cut out."""
    frames, scan = one_turn(media)
    if not frames:
        return [], False
    if not scan:
        matched = cover_frame(listing)
        start = next((i for i, f in enumerate(frames) if f.original_url == matched), 0)
        frames = frames[start:] + frames[:start]
    cut = all(f.processed_url for f in frames)
    return [(f.thumb_url if f.thumb_url and (cut or not f.processed_url) else full, full)
            for f in frames for full in [f.processed_url if cut else f.original_url]], cut


# The app's stage behind a cut-out turn, light or dark as suits the shoe (ShowcaseScene in scroll_showcase.dart).
SCENES = {"light": "radial-gradient(circle at 50% 50%, #f7f6fa, #e8e6ee 70%)",
          "dark": "radial-gradient(circle at 50% 50%, #17161f, #0e0e14 70%)"}


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
