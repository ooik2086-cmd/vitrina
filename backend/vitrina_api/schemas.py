"""Request bodies the API accepts, validated before any handler runs."""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from vitrina_core.catalog import Condition

from .api_common import CATEGORIES


class OtpRequest(BaseModel):
    phone: str


class OtpVerify(BaseModel):
    phone: str
    code: str = Field(min_length=6, max_length=6)


class ProfilePatch(BaseModel):
    display_name: str | None = Field(default=None, min_length=2, max_length=60)
    city: str | None = Field(default=None, max_length=60)


class SellerOn(BaseModel):
    shop_name: str = Field(min_length=2, max_length=80)
    city: str = Field(min_length=2, max_length=60)


class SizeIn(BaseModel):
    label: str = Field(min_length=1, max_length=20)
    insole_cm: str
    quantity: int = Field(ge=0, le=999)


class PhotoIn(BaseModel):
    url: str = Field(min_length=8, max_length=500)
    angle: Literal["front", "outer", "inner", "back", "top", "sole", "label", "defect", "frame"]


class ListingIn(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    category: Literal[CATEGORIES]  # type: ignore[valid-type]
    brand: str | None = Field(default=None, max_length=60)
    model_name: str | None = Field(default=None, max_length=80)
    color: str = Field(min_length=2, max_length=40)
    condition: Condition
    defects: str | None = Field(default=None, max_length=2000)
    description: str | None = Field(default=None, max_length=4000)
    price_tiyn: int = Field(gt=0, le=10**12)
    delivery_price_tiyn: int = Field(ge=0, le=10**10, default=0)
    showcase_style: Literal["clean", "premium", "dynamic"] = "clean"
    sizes: list[SizeIn] = Field(min_length=1, max_length=30)
    photos: list[PhotoIn] = Field(default_factory=list, max_length=60)


class StockIn(BaseModel):
    id: int
    quantity: int = Field(ge=0, le=999)


class ListingPatch(BaseModel):
    """What a seller may change after creating a listing.
    Before it ever sells (draft, rejected) everything can change. Once it is or was on sale, the shoe itself is
    fixed for buyers who saved, asked about or ordered it: category, condition and the photos already shown stay,
    but the seller may add photos, a 360° view, sizes, and improve the name. Every change a buyer sees is checked
    again before it is shown."""
    price_tiyn: int | None = Field(default=None, gt=0, le=10**12)
    delivery_price_tiyn: int | None = Field(default=None, ge=0, le=10**10)
    description: str | None = Field(default=None, max_length=4000)
    defects: str | None = Field(default=None, max_length=2000)
    sizes: list[StockIn] | None = Field(default=None, max_length=30)
    title: str | None = Field(default=None, min_length=3, max_length=120)
    brand: str | None = Field(default=None, max_length=60)
    model_name: str | None = Field(default=None, max_length=80)
    color: str | None = Field(default=None, min_length=2, max_length=40)
    category: Literal[CATEGORIES] | None = None  # type: ignore[valid-type]
    condition: Condition | None = None
    photos: list[PhotoIn] | None = Field(default=None, max_length=60)  # the whole set; only before it sells
    add_photos: list[PhotoIn] | None = Field(default=None, max_length=60)
    add_sizes: list[SizeIn] | None = Field(default=None, max_length=30)


class DeliveryIn(BaseModel):
    recipient_name: str = Field(min_length=2, max_length=80)
    recipient_phone: str
    city: str = Field(min_length=2, max_length=60)
    address: str = Field(min_length=5, max_length=200)  # street, house, flat
    note: str | None = Field(default=None, max_length=200)


class OrderIn(BaseModel):
    listing_id: int
    size_id: int
    offer_id: int | None = None  # an accepted price offer for this listing and size
    promo_code: str | None = Field(default=None, max_length=20)  # the seller's code; not with an offer
    delivery: DeliveryIn


class ShipIn(BaseModel):
    tracking_number: str = Field(max_length=60)


class ReasonIn(BaseModel):
    reason: str = Field(max_length=2000)


class ReportIn(BaseModel):
    reason: Literal["fake", "wrong_photos", "prohibited", "contact_details", "other"]
    text: str | None = Field(default=None, max_length=1000)


class ReportCloseIn(BaseModel):
    action: Literal["hide", "dismiss"]
    reason: str = Field(min_length=3, max_length=2000)


class ResolveIn(BaseModel):
    refund_tiyn: int = Field(ge=0)
    reason: str = Field(max_length=2000)
