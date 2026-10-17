"""Packing slip: one A6 page the seller prints and puts in or on the box.

It carries what a courier and the buyer need and nothing more: the order number, who it goes to, the pair and its
size. The buyer's address exists on the order only after payment, so there is no slip before that.
"""
from __future__ import annotations

import io
from datetime import timedelta, timezone

from fastapi import APIRouter, Depends
from fastapi.responses import Response
from PIL import Image, ImageDraw
from sqlalchemy.orm import Session

from vitrina_core.orders import OrderStatus as S

from . import services
from .deps import current_user, get_db
from .errors import ApiError
from .models import Listing, ListingSize, Order, User
from .promo import font

router = APIRouter(prefix="/api/v1")

ALMATY = timezone(timedelta(hours=5))
DPI = 300
W, H = 1240, 1748  # A6 portrait at 300 dpi
MARGIN = 90
INK, MUTED, LINE = (14, 14, 16), (110, 110, 118), (210, 210, 214)
# From payment until the box has left: the only time a slip is useful.
PRINTABLE = (S.PAID.value, S.SELLER_ACCEPTED.value, S.PREPARING.value, S.SHIPPED.value)


def wrap(draw: ImageDraw.ImageDraw, text: str, f, width: int) -> list[str]:
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=f) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    return lines + ([line] if line else [])


def render(order: Order, listing: Listing, size: ListingSize | None, seller: User) -> bytes:
    page = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(page)
    width = W - 2 * MARGIN
    y = MARGIN

    def block(label: str, lines: list[tuple[str, int, str]], gap: int = 36) -> None:
        nonlocal y
        d.text((MARGIN, y), label.upper(), font=font(30, "SemiBold"), fill=MUTED)
        y += 48
        for text, size_px, weight in lines:
            f = font(size_px, weight)
            for part in wrap(d, text, f, width):
                d.text((MARGIN, y), part, font=f, fill=INK)
                y += int(size_px * 1.3)
        y += gap
        d.line((MARGIN, y, W - MARGIN, y), fill=LINE, width=3)
        y += gap

    d.text((MARGIN, y), "VITRINA", font=font(56, "Bold"), fill=INK)
    number = f"№ {order.id}"
    big = font(96, "Bold")
    d.text((W - MARGIN - d.textlength(number, font=big), y - 20), number, font=big, fill=INK)
    y += 120
    d.line((MARGIN, y, W - MARGIN, y), fill=INK, width=6)
    y += 50

    block("Кімге / Кому", [(order.recipient_name or "", 64, "Bold"), (order.recipient_phone or "", 48, "Regular"),
                           (order.delivery_city or "", 56, "SemiBold"), (order.delivery_address or "", 46, "Regular")]
          + ([(f"Ескерту: {order.delivery_note}", 38, "Regular")] if order.delivery_note else []))
    block("Кімнен / От", [(seller.shop_name or "", 46, "SemiBold"), (seller.city or "", 40, "Regular")])
    item = [(order.listing_title or listing.title, 44, "SemiBold")]
    if size is not None:
        item.append((f"Өлшем / Размер: {size.label}", 44, "Regular"))
    block("Тауар / Товар", item)
    paid = services.aware(order.created_at).astimezone(ALMATY).strftime("%d.%m.%Y")
    d.text((MARGIN, y), f"Тапсырыс күні / Дата заказа: {paid}", font=font(34), fill=MUTED)
    y += 60
    if order.tracking_number:
        d.text((MARGIN, y), f"Трек-нөмір: {order.tracking_number}", font=font(40, "SemiBold"), fill=INK)
    foot = "Қорғалған төлем: ақша сатып алушы растағанша сақталады."
    d.text((MARGIN, H - MARGIN - 40), foot, font=font(30), fill=MUTED)

    out = io.BytesIO()
    page.save(out, "PDF", resolution=DPI)
    return out.getvalue()


@router.get("/orders/{order_id}/slip.pdf")
def packing_slip(order_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    order = db.get(Order, order_id)
    if order is None or order.seller_id != user.id:
        raise ApiError(404, "not_found")
    if order.status not in PRINTABLE or not order.recipient_name:
        raise ApiError(409, "invalid_status")
    pdf = render(order, db.get(Listing, order.listing_id), db.get(ListingSize, order.size_id), user)
    return Response(pdf, media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="vitrina-{order.id}.pdf"'})
