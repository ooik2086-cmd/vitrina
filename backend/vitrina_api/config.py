"""Settings come from environment variables; nothing secret is hard-coded for production."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import timedelta

from vitrina_core.money import CommissionRule


@dataclass
class Settings:
    # "production" turns on the startup check below; anything else is development.
    env: str = field(default_factory=lambda: os.environ.get("VITRINA_ENV", "development"))
    database_url: str = field(default_factory=lambda: os.environ.get("VITRINA_DATABASE_URL", "sqlite:///./vitrina-dev.db"))
    # Development only: returns the OTP in the API response because no SMS provider is connected yet.
    debug_otp: bool = field(default_factory=lambda: os.environ.get("VITRINA_DEBUG_OTP", "1") == "1")
    otp_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_OTP_SECRET", "dev-otp-secret").encode())
    payment_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_PAYMENT_SECRET", "dev-payment-secret").encode())
    delivery_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_DELIVERY_SECRET", "dev-delivery-secret").encode())
    otp_ttl: timedelta = timedelta(minutes=5)
    otp_max_attempts: int = 5
    otp_per_phone_per_hour: int = 5
    # A second code for the same phone waits this long: people tap "send again" before the first SMS arrives.
    otp_resend_after: timedelta = timedelta(seconds=60)
    token_ttl: timedelta = timedelta(days=30)
    # Buyer confirmation window before auto-complete. Hypothesis: the real value needs legal review.
    confirm_window: timedelta = timedelta(days=5)
    commission: CommissionRule = field(default_factory=lambda: CommissionRule(version="pilot-2026-10", rate_bp=500))
    min_listing_photos: int = 4
    # Seconds between passes of the time-based jobs (vitrina_api/jobs.py) inside the API process. 0 = off, for
    # tests and for deployments that run `python -m vitrina_api.jobs` from cron.
    jobs_interval_s: int = field(default_factory=lambda: int(os.environ.get("VITRINA_JOBS_INTERVAL", "0")))
    # Development and tests create tables directly. Production sets this to 0 and runs `alembic upgrade head`.
    auto_create_schema: bool = field(default_factory=lambda: os.environ.get("VITRINA_AUTO_CREATE_SCHEMA", "1") == "1")
    # Uploaded photos on local disk, used when no S3 bucket is set (development and tests).
    media_dir: str = field(default_factory=lambda: os.environ.get("VITRINA_MEDIA_DIR", "./media-dev"))
    public_media_url: str = field(default_factory=lambda: os.environ.get("VITRINA_PUBLIC_MEDIA_URL", "http://127.0.0.1:8000/media"))
    # S3-compatible bucket for photos and videos. Set the bucket to use it; VITRINA_PUBLIC_MEDIA_URL is then the
    # bucket's public address (or a CDN in front of it). Keys come from the environment, never from the code.
    s3_endpoint: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_ENDPOINT", ""))
    s3_bucket: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_BUCKET", ""))
    s3_region: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_REGION", "us-east-1"))
    s3_access_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_ACCESS_KEY", ""))
    s3_secret_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_SECRET_KEY", ""))
    # Listings may only reference photos uploaded through /media, so sellers cannot embed tracking pixels or hotlinks.
    allow_external_media: bool = field(default_factory=lambda: os.environ.get("VITRINA_ALLOW_EXTERNAL_MEDIA", "0") == "1")
    # Browser origins allowed to call the API (the Flutter web build during development). Empty = none.
    # Path to a background-removal model (backend/models/README.md). Empty = keep original photos only.
    cutout_model: str = field(default_factory=lambda: os.environ.get("VITRINA_CUTOUT_MODEL", ""))
    # Search-by-photo model (backend/models/README.md). Empty = search by photo answers 503.
    search_model: str = field(default_factory=lambda: os.environ.get("VITRINA_SEARCH_MODEL", ""))
    cors_origins: list[str] = field(default_factory=lambda: [o for o in os.environ.get("VITRINA_CORS_ORIGINS", "").split(",") if o])


def production_problems(s: Settings) -> list[str]:
    """What would make a live server unsafe. In production the API refuses to start while any of these hold,
    so a forgotten development default can never take real money or show sign-in codes."""
    problems = []
    if s.debug_otp:
        problems.append("VITRINA_DEBUG_OTP must be 0: sign-in codes would be returned in API responses")
    for env, value in (("VITRINA_OTP_SECRET", s.otp_secret), ("VITRINA_PAYMENT_SECRET", s.payment_webhook_secret),
                       ("VITRINA_DELIVERY_SECRET", s.delivery_webhook_secret)):
        if value.startswith(b"dev-") or len(value) < 32:
            problems.append(f"{env} must be a random value of at least 32 characters")
    if s.auto_create_schema:
        problems.append("VITRINA_AUTO_CREATE_SCHEMA must be 0: the schema comes from `alembic upgrade head`")
    if s.database_url.startswith("sqlite"):
        problems.append("VITRINA_DATABASE_URL must point at PostgreSQL")
    if any(o.startswith("http://") for o in s.cors_origins) or s.public_media_url.startswith("http://"):
        problems.append("VITRINA_CORS_ORIGINS and VITRINA_PUBLIC_MEDIA_URL must use https")
    if "*" in s.cors_origins:
        problems.append("VITRINA_CORS_ORIGINS must list the app's origins, not *")
    if s.allow_external_media:
        problems.append("VITRINA_ALLOW_EXTERNAL_MEDIA must be 0: listings could show images from any site")
    if not s.s3_bucket:
        problems.append("VITRINA_S3_BUCKET must be set: photos on the API server's disk are lost with the server")
    elif not (s.s3_endpoint.startswith("https://") and s.s3_access_key and s.s3_secret_key):
        problems.append("VITRINA_S3_ENDPOINT (https), VITRINA_S3_ACCESS_KEY and VITRINA_S3_SECRET_KEY must be set")
    return problems
