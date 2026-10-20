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
    # Online payment: "sandbox" (development and tests: signed test webhooks mark orders paid) or "off" (no
    # licensed payment partner yet: no orders or price offers, the app offers a chat with the seller instead).
    payments: str = field(default_factory=lambda: os.environ.get("VITRINA_PAYMENTS", "sandbox"))
    # Who runs the site and where people write about their data, as the public /privacy page names them (the
    # personal-data law): e.g. "ИП Сапар А., ИИН 000000000000" and "help@vitrina.kz".
    operator: str = field(default_factory=lambda: os.environ.get("VITRINA_OPERATOR", "").strip())
    support_contact: str = field(default_factory=lambda: os.environ.get("VITRINA_SUPPORT_CONTACT", "").strip())
    payment_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_PAYMENT_SECRET", "dev-payment-secret").encode())
    delivery_webhook_secret: bytes = field(default_factory=lambda: os.environ.get("VITRINA_DELIVERY_SECRET", "dev-delivery-secret").encode())
    otp_ttl: timedelta = timedelta(minutes=5)
    otp_max_attempts: int = 5
    otp_per_phone_per_hour: int = 5
    # A second code for the same phone waits this long: people tap "send again" before the first SMS arrives.
    otp_resend_after: timedelta = timedelta(seconds=60)
    # Sign-in codes by SMS (vitrina_api/sms.py): "mobizon", or empty in development (the code is in the answer).
    sms_provider: str = field(default_factory=lambda: os.environ.get("VITRINA_SMS_PROVIDER", ""))
    mobizon_api_key: str = field(default_factory=lambda: os.environ.get("VITRINA_MOBIZON_API_KEY", ""))
    mobizon_url: str = field(default_factory=lambda: os.environ.get("VITRINA_MOBIZON_URL", "https://api.mobizon.kz"))
    # A sender name registered in the Mobizon account; empty: Mobizon's shared one.
    mobizon_from: str = field(default_factory=lambda: os.environ.get("VITRINA_MOBIZON_FROM", ""))
    # Codes sent per day at most, across all API processes: someone cycling through numbers cannot empty the SMS
    # balance (each code costs money), while 2 000 is far above what real sign-ins need for now.
    sms_per_day: int = field(default_factory=lambda: int(os.environ.get("VITRINA_SMS_PER_DAY", "2000")))
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
    # Where photos and private files live: "s3" (the buckets below) or "disk" (media_dir and private_media_dir, on
    # the server's own disk; Caddy serves media_dir at /media). Production must name one; empty: s3 when a bucket
    # is set, else disk (development and tests).
    storage: str = field(default_factory=lambda: os.environ.get("VITRINA_STORAGE", ""))
    # Uploaded photos on local disk, used when no S3 bucket is set (development, tests and VITRINA_STORAGE=disk).
    media_dir: str = field(default_factory=lambda: os.environ.get("VITRINA_MEDIA_DIR", "./media-dev"))
    public_media_url: str = field(default_factory=lambda: os.environ.get("VITRINA_PUBLIC_MEDIA_URL", "http://127.0.0.1:8000/media"))
    # S3-compatible bucket for photos and videos. Set the bucket to use it; VITRINA_PUBLIC_MEDIA_URL is then the
    # bucket's public address (or a CDN in front of it). Keys come from the environment, never from the code.
    s3_endpoint: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_ENDPOINT", ""))
    s3_bucket: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_BUCKET", ""))
    s3_region: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_REGION", "us-east-1"))
    s3_access_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_ACCESS_KEY", ""))
    s3_secret_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_SECRET_KEY", ""))
    # Files only the people involved may see (authenticity proofs: receipts, boxes; dispute evidence): a second,
    # non-public bucket, read through links that expire. Without a bucket they sit in private_media_dir and the API
    # serves them at /api/v1/private-media with a signed link.
    s3_private_bucket: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_PRIVATE_BUCKET", ""))
    # Copies of the database (python -m vitrina_api.backup, deploy/backup.sh): a third bucket, not public either.
    s3_backup_bucket: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_BACKUP_BUCKET", ""))
    # Its own key, if the provider can scope one to that bucket (empty: the photos' key).
    s3_backup_access_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_BACKUP_ACCESS_KEY", ""))
    s3_backup_secret_key: str = field(default_factory=lambda: os.environ.get("VITRINA_S3_BACKUP_SECRET_KEY", ""))
    private_media_dir: str = field(default_factory=lambda: os.environ.get("VITRINA_PRIVATE_MEDIA_DIR", "./media-private-dev"))
    # The API's own address as phones reach it, for links to private files kept on disk. Empty: the origin of
    # VITRINA_PUBLIC_MEDIA_URL, which is right while the API serves /media itself (no public bucket).
    public_api_url: str = field(default_factory=lambda: os.environ.get("VITRINA_PUBLIC_API_URL", ""))
    # Listings may only reference photos uploaded through /media, so sellers cannot embed tracking pixels or hotlinks.
    allow_external_media: bool = field(default_factory=lambda: os.environ.get("VITRINA_ALLOW_EXTERNAL_MEDIA", "0") == "1")
    # Browser origins allowed to call the API (the Flutter web build during development). Empty = none.
    # Where the photo work of new and edited listings runs (cut-outs take minutes of every core per listing):
    # "inline" in the API process after answering, for development and tests; "worker" leaves it to
    # `python -m vitrina_api.photo_worker`, which a live deployment runs so buyers are not slowed down.
    photo_work: str = field(default_factory=lambda: os.environ.get("VITRINA_PHOTO_WORK", "inline"))
    photo_worker_interval_s: float = field(
        default_factory=lambda: float(os.environ.get("VITRINA_PHOTO_WORKER_INTERVAL", "5")))
    photo_worker_nice: int = field(default_factory=lambda: int(os.environ.get("VITRINA_PHOTO_WORKER_NICE", "10")))
    photo_worker_alive: str = field(
        default_factory=lambda: os.environ.get("VITRINA_PHOTO_WORKER_ALIVE", "/tmp/photo_worker.alive"))
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
    if s.sms_provider != "mobizon" or not s.mobizon_api_key:
        problems.append("VITRINA_SMS_PROVIDER=mobizon and VITRINA_MOBIZON_API_KEY must be set: without them sign-in "
                        "codes are sent nowhere and nobody can sign in")
    elif not s.mobizon_url.startswith("https://"):
        problems.append("VITRINA_MOBIZON_URL must use https: the key travels in it")
    if not s.operator or not s.support_contact:
        problems.append("VITRINA_OPERATOR and VITRINA_SUPPORT_CONTACT must be set: the privacy page and the "
                        "account-deletion page name who runs the site and where to write")
    if s.payments != "off":
        problems.append("VITRINA_PAYMENTS must be off: there is no licensed payment partner yet, and with sandbox "
                        "buyers would place orders nobody can pay")
    if s.photo_work != "worker":
        problems.append("VITRINA_PHOTO_WORK must be worker, with `python -m vitrina_api.photo_worker` running: "
                        "cutting out photos inside the API slows every buyer down for minutes")
    if s.allow_external_media:
        problems.append("VITRINA_ALLOW_EXTERNAL_MEDIA must be 0: listings could show images from any site")
    if s.storage == "s3":
        if not s.s3_bucket:
            problems.append("VITRINA_S3_BUCKET must be set with VITRINA_STORAGE=s3")
        if not s.s3_private_bucket or s.s3_private_bucket == s.s3_bucket:
            problems.append("VITRINA_S3_PRIVATE_BUCKET must name a second bucket without public read: receipts and "
                            "dispute evidence must not be reachable by address")
        if not s.s3_backup_bucket or s.s3_backup_bucket in (s.s3_bucket, s.s3_private_bucket):
            problems.append("VITRINA_S3_BACKUP_BUCKET must name a third bucket without public read: the database's "
                            "nightly copies must outlive the server")
    elif s.storage == "disk":
        # Photos at https://SITE/media (Caddy serves the folder), private files through the API's signed links.
        if s.s3_bucket or s.s3_private_bucket:
            problems.append("VITRINA_S3_BUCKET and VITRINA_S3_PRIVATE_BUCKET must be empty with VITRINA_STORAGE=disk")
        if not s.public_api_url.startswith("https://"):
            problems.append("VITRINA_PUBLIC_API_URL must be the site's https address: links to private files name it")
        elif s.public_media_url.rstrip("/") != s.public_api_url.rstrip("/") + "/media":
            problems.append("VITRINA_PUBLIC_MEDIA_URL must be VITRINA_PUBLIC_API_URL + /media with "
                            "VITRINA_STORAGE=disk: that is where Caddy serves the photos")
        if not (os.path.isabs(s.media_dir) and os.path.isabs(s.private_media_dir)):
            problems.append("VITRINA_MEDIA_DIR and VITRINA_PRIVATE_MEDIA_DIR must be absolute (the volumes)")
    else:
        problems.append("VITRINA_STORAGE must be disk (the server's own disk) or s3 (buckets)")
    if s.s3_bucket or s.s3_private_bucket:
        if not (s.s3_endpoint.startswith("https://") and s.s3_access_key and s.s3_secret_key):
            problems.append("VITRINA_S3_ENDPOINT (https), VITRINA_S3_ACCESS_KEY and VITRINA_S3_SECRET_KEY must be "
                            "set for the buckets")
    elif s.s3_backup_bucket and not s.s3_endpoint.startswith("https://"):
        # The backup bucket alone (optional on disk): the API never uses it, so its key may live in backup.env only,
        # out of the running services' reach; backup.sh says so if there is none.
        problems.append("VITRINA_S3_ENDPOINT must be the backup bucket's https address")
    return problems
