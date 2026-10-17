"""Settings come from environment variables; nothing secret is hard-coded for production."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import timedelta

from vitrina_core.money import CommissionRule


@dataclass
class Settings:
    database_url: str = field(default_factory=lambda: os.environ.get("VITRINA_DATABASE_URL", "sqlite:///./vitrina-dev.db"))
    # Development only: returns the OTP in the API response because no SMS provider is connected yet.
    debug_otp: bool = field(default_factory=lambda: os.environ.get("VITRINA_DEBUG_OTP", "1") == "1")
    otp_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_OTP_SECRET", "dev-otp-secret").encode())
    payment_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_PAYMENT_SECRET", "dev-payment-secret").encode())
    delivery_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_DELIVERY_SECRET", "dev-delivery-secret").encode())
    otp_ttl: timedelta = timedelta(minutes=5)
    otp_max_attempts: int = 5
    otp_per_phone_per_hour: int = 5
    token_ttl: timedelta = timedelta(days=30)
    # Buyer confirmation window before auto-complete. Hypothesis: the real value needs legal review.
    confirm_window: timedelta = timedelta(days=5)
    commission: CommissionRule = field(default_factory=lambda: CommissionRule(version="pilot-2026-10", rate_bp=500))
    min_listing_photos: int = 4
    # Development and tests create tables directly. Production sets this to 0 and runs `alembic upgrade head`.
    auto_create_schema: bool = field(default_factory=lambda: os.environ.get("VITRINA_AUTO_CREATE_SCHEMA", "1") == "1")
    # Uploaded photos. Local disk in development; production replaces LocalStorage with an S3-compatible bucket.
    media_dir: str = field(default_factory=lambda: os.environ.get("VITRINA_MEDIA_DIR", "./media-dev"))
    public_media_url: str = field(default_factory=lambda: os.environ.get("VITRINA_PUBLIC_MEDIA_URL", "http://127.0.0.1:8000/media"))
    # Listings may only reference photos uploaded through /media, so sellers cannot embed tracking pixels or hotlinks.
    allow_external_media: bool = field(default_factory=lambda: os.environ.get("VITRINA_ALLOW_EXTERNAL_MEDIA", "0") == "1")
    # Browser origins allowed to call the API (the Flutter web build during development). Empty = none.
    # Path to a background-removal model (backend/models/README.md). Empty = keep original photos only.
    cutout_model: str = field(default_factory=lambda: os.environ.get("VITRINA_CUTOUT_MODEL", ""))
    # Search-by-photo model (backend/models/README.md). Empty = search by photo answers 503.
    search_model: str = field(default_factory=lambda: os.environ.get("VITRINA_SEARCH_MODEL", ""))
    cors_origins: list[str] = field(default_factory=lambda: [o for o in os.environ.get("VITRINA_CORS_ORIGINS", "").split(",") if o])
