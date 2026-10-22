"""Request bodies the API accepts, validated before any handler runs."""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, field_validator

from vitrina_core.catalog import Condition
from vitrina_core.colors import canonical_color

from .api_common import AUDIENCES, CATEGORIES


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
    angle: Literal["front", "outer", "inner", "back", "top", "sole", "detail", "label", "defect", "frame"]


class ListingIn(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    category: Literal[CATEGORIES]  # type: ignore[valid-type]
    audience: Literal[AUDIENCES] | None = None  # type: ignore[valid-type]
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
    # Picked from ready options (vitrina_core/facts.py), checked against the kind of footwear when saved.
    facts: dict[str, str] | None = Field(default=None, max_length=12)

    # "Черный" and "black" are stored as "қара": one colour of a model is one swatch.
    _color = field_validator("color", mode="before")(lambda v: canonical_color(v) if isinstance(v, str) else v)


class StockIn(BaseModel):
    id: int
    quantity: int = Field(ge=0, le=999)
    # The count the seller's screen showed: if a buyer took a pair since, the seller sees the new count first.
    was: int | None = Field(default=None, ge=0, le=999)


class ListingPatch(BaseModel):
    """What a seller may change after creating a listing.
    Before it ever sells (draft, rejected) everything can change. Once it is or was on sale, the shoe itself is
    fixed for buyers who saved, asked about or ordered it: brand, model and category stay and the condition may only
    get worse. Photos and the 360° view may be replaced: each order keeps a copy of the photos it was placed on.
    Every change a buyer sees is checked again before it is shown."""
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
    audience: Literal[AUDIENCES] | None = None  # type: ignore[valid-type]
    condition: Condition | None = None
    photos: list[PhotoIn] | None = Field(default=None, max_length=60)  # the whole set, replacing the current one
    add_photos: list[PhotoIn] | None = Field(default=None, max_length=60)
    add_sizes: list[SizeIn] | None = Field(default=None, max_length=30)
    cover_frame: str | None = Field(default=None, max_length=500)  # the 360° frame that matches the cover
    facts: dict[str, str] | None = Field(default=None, max_length=12)  # all of them, replacing those kept; {} clears

    _color = field_validator("color", mode="before")(lambda v: canonical_color(v) if isinstance(v, str) else v)


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
    # The listing's photos_version as the buyer saw it; older apps leave it out and get today's photos.
    photos_version: str | None = Field(default=None, max_length=32)
    promo_code: str | None = Field(default=None, max_length=20)  # the seller's code; not with an offer
    delivery: DeliveryIn


class ShipIn(BaseModel):
    tracking_number: str = Field(max_length=60)


class ReasonIn(BaseModel):
    reason: str = Field(max_length=2000)


class ListingModelIn(BaseModel):
    """A listing's 3D model: glTF binary files over https, and the colour among the model's own variants."""
    url: str = Field(max_length=500, pattern=r"^https://[^\s]+\.glb$")
    hq_url: str | None = Field(default=None, max_length=500, pattern=r"^https://[^\s]+\.glb$")
    variant: str | None = Field(default=None, max_length=40, pattern=r"^[A-Za-z0-9_-]+$")
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
    # Decide before both sides had their 48 hours (the case is plain, or one side has already said all it will).
    early: bool = False


class EvidenceRequestIn(BaseModel):
    side: Literal["buyer", "seller"]
    note: str = Field(min_length=3, max_length=500)
