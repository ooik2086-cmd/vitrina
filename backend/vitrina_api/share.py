"""Public page for a shared listing link: /l/{id}.

Messengers (WhatsApp, Telegram, Instagram DMs) read the Open Graph tags and show the shoe's photo, title and
price as a preview. Someone without the app can turn the shoe on the page itself, from the seller's real 360°
frames, and open it in the app with one tap. Only published listings are shown; no seller phone, ever.
"""
from __future__ import annotations

import html
import json

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from . import promo
from .deps import get_db
from .models import Listing, User

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
           "gone": "Бұл тауар енді сатылымда жоқ.", "seller": "Сатушы"},
    "ru": {"open": "Открыть в приложении", "drag": "Проведите, чтобы повернуть", "sizes": "Размеры",
           "delivery": "Доставка", "free": "бесплатно",
           "protected": "Деньги хранятся, пока покупатель не получит товар и не подтвердит это.",
           "gone": "Этот товар больше не продаётся.", "seller": "Продавец"},
    "en": {"open": "Open in the app", "drag": "Drag to turn", "sizes": "Sizes", "delivery": "Delivery", "free": "free",
           "protected": "The money is held until the buyer receives the item and confirms it.",
           "gone": "This listing is no longer on sale.", "seller": "Seller"},
}
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
    frames = [m.processed_url or m.original_url for m in media if m.angle == "frame"]
    showcase = [m for m in media if m.angle in SHOWCASE]
    shots = frames or [m.processed_url or m.original_url for m in showcase]
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
        spin_js = f"""<script>
(() => {{
  const urls = {json.dumps(shots)}, img = document.getElementById('shot'), stage = document.getElementById('stage');
  urls.forEach(u => {{ const i = new Image(); i.src = u; }});
  let k = 0, x0 = null, k0 = 0;
  const show = n => {{ k = ((n % urls.length) + urls.length) % urls.length; img.src = urls[k]; }};
  stage.addEventListener('pointerdown', e => {{ x0 = e.clientX; k0 = k; stage.setPointerCapture(e.pointerId); }});
  stage.addEventListener('pointermove', e => {{ if (x0 !== null) show(k0 + Math.round((e.clientX - x0) / 12)); }});
  stage.addEventListener('pointerup', () => {{ x0 = null; }});
  let turn = 0; const auto = setInterval(() => {{ if (x0 === null) show(k + 1); if (++turn >= urls.length) clearInterval(auto); }}, 70);
}})();
</script>"""
    stage = (f'<div class="stage" id="stage" style="background:{backdrop}">'
             f'<img id="shot" alt="{esc(listing.title)}" src="{esc(shots[0])}" draggable="false">'
             + (f'<div class="hint">↔ {t["drag"]}</div>' if len(shots) > 1 else "") + "</div>") if shots else ""
    body = f"""{stage}
<div class="info">
<h1>{esc(listing.title)}</h1>
<div class="price">{esc(price)}</div>
<div class="muted">{esc(description)} · {t["delivery"]} {esc(delivery)}</div>
<h3>{t["sizes"]}</h3><div class="chips">{sizes}</div>
<a class="cta" href="vitrina://open/listing/{listing.id}">{t["open"]}</a>
<p class="note muted">{t["protected"]}</p>
</div>{spin_js}"""
    return page(f"{listing.title} · {price} · VITRINA", body, lang=lang, meta=meta)
