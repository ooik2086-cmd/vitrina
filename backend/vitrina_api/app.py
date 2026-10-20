"""VITRINA API v1 (modular monolith). Run: uvicorn vitrina_api.app:create_app --factory --reload"""
from __future__ import annotations

import asyncio
import logging
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles

from . import authenticity, coupons, cutout, delivery_eta, jobs, offers, payouts, private_media, qa, slip, visual
from .config import Settings, production_problems
from .errors import ApiError, api_error_handler
from .share import router as share_router
from .social import router as social_router
from .models import make_session_factory
from .storage import MAX_UPLOAD_BYTES, make_private_storage, make_storage
from .api_common import log
from .auth_routes import OTP_REQUESTS_PER_ADDRESS_PER_HOUR
from .order_routes import EVIDENCE_TRIES_PER_HOUR
from .search_routes import IMAGE_SEARCH_PER_MINUTE, SlidingWindowLimiter
from .webhook_routes import hooks
from . import (auth_routes, listing_routes, order_routes, saved_search_routes, search_routes, seller_routes,
               staff_routes)

# Included in this order, which is the order paths are matched in: a literal path such as /listings/suggest must
# come before a pattern such as /listings/{listing_id} with the same method.
ROUTE_MODULES = (auth_routes, listing_routes, search_routes, seller_routes, saved_search_routes, order_routes,
                 staff_routes)


def logging_setup() -> None:
    """Our own loggers ("vitrina.*") print INFO and up on stderr under uvicorn too; without this, job results and
    errors were dropped by the default logging setup. One line per record, easy to ship to a log store."""
    root = logging.getLogger("vitrina")
    if root.handlers:
        return
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter('{"at":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s",'
                                           '"msg":%(message)r}'))
    root.addHandler(handler)
    root.setLevel(os.environ.get("VITRINA_LOG_LEVEL", "INFO").upper())
    root.propagate = False


# Largest request body accepted: one photo or video upload plus the multipart framing around it.
MAX_REQUEST_BYTES = MAX_UPLOAD_BYTES + 64 * 1024
# The console loads only its own files; share pages may also show photos from the media host.
ADMIN_CSP = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' https: data:; media-src 'self' https:; frame-ancestors 'none'"
SHARE_CSP = "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'unsafe-inline'; img-src 'self' https: data:; media-src 'self' https:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"


class CompressText:
    """gzip for JSON and pages. A page of the catalog is ~200 KB of JSON and ~35 KB compressed: on a phone's mobile
    data that is most of the wait; the app (dart:io) asks for gzip and unpacks it by itself. Photos, videos and PDFs
    are compressed already, and a video is fetched in ranges that gzip would break."""

    def __init__(self, app):
        self.app, self.gzip = app, GZipMiddleware(app, minimum_size=1000, compresslevel=5)

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "") if scope["type"] == "http" else ""
        text = path and not path.startswith(("/media/", "/api/v1/private-media/")) and not path.endswith(".pdf")
        await (self.gzip if text else self.app)(scope, receive, send)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    logging_setup()
    if settings.env == "production" and (problems := production_problems(settings)):
        raise RuntimeError("Refusing to start in production:\n- " + "\n- ".join(problems))

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        task = (asyncio.create_task(jobs.loop(app.state.sessions, settings, settings.jobs_interval_s))
                if settings.jobs_interval_s > 0 else None)
        yield
        if task:
            task.cancel()

    app = FastAPI(title="VITRINA API", version="0.1.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.sessions = make_session_factory(settings.database_url, create_schema=settings.auto_create_schema)
    app.state.storage = make_storage(settings)
    app.state.private = make_private_storage(settings)
    # Only photo work cuts out, and with a photo worker that is not here: ~440 MB per API process saved.
    app.state.segmenter = (None if settings.photo_work == "worker"
                           else cutout.load_segmenter(settings.cutout_model))
    app.state.embedder = visual.load_embedder(settings.search_model)
    app.state.image_search_limiter = SlidingWindowLimiter(IMAGE_SEARCH_PER_MINUTE, 60)
    app.state.otp_limiter = SlidingWindowLimiter(OTP_REQUESTS_PER_ADDRESS_PER_HOUR, 3600)
    app.state.evidence_limiter = SlidingWindowLimiter(EVIDENCE_TRIES_PER_HOUR, 3600)
    app.add_exception_handler(ApiError, api_error_handler)

    async def validation_handler(request: Request, exc: RequestValidationError):
        return await api_error_handler(request, ApiError(422, "validation", str(exc.errors()[:3])))

    app.add_exception_handler(RequestValidationError, validation_handler)

    async def unexpected_handler(request: Request, exc: Exception):
        # Anything unplanned (database or storage down, a bug) is logged with the request id and answered in the
        # usual error shape, so the app shows its own translated "try again" instead of raw text.
        log.exception("unhandled error on %s %s [%s]", request.method, request.url.path,
                      getattr(request.state, "request_id", "-"))
        response = await api_error_handler(request, ApiError(503, "unavailable"))
        # This runs outside the middleware below, so the id the log line carries is attached here.
        response.headers["X-Request-ID"] = getattr(request.state, "request_id", "-")
        return response

    app.add_exception_handler(Exception, unexpected_handler)

    @app.middleware("http")
    async def guard(request: Request, call_next):
        request.state.request_id = request.headers.get("X-Request-ID") or secrets.token_hex(8)
        # Refuse oversized bodies before anything parses them; uploads are the only large requests we accept.
        length = request.headers.get("content-length")
        if length is not None and (not length.isdigit() or int(length) > MAX_REQUEST_BYTES):
            return await api_error_handler(request, ApiError(413, "file_too_large"))
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        path = request.url.path
        # Pages a browser renders: the support console and the public share pages, which show seller content.
        if path.startswith(("/admin", "/l/", "/s/")):
            response.headers.setdefault("X-Frame-Options", "DENY")
            response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
            response.headers.setdefault("Content-Security-Policy", ADMIN_CSP if path.startswith("/admin") else SHARE_CSP)
        return response

    for module in ROUTE_MODULES:
        app.include_router(module.router)
    app.include_router(hooks)
    app.include_router(social_router)
    app.include_router(share_router)
    app.include_router(offers.router)
    app.include_router(authenticity.router)
    app.include_router(coupons.router)
    app.include_router(payouts.router)
    app.include_router(delivery_eta.router)
    app.include_router(slip.router)
    app.include_router(qa.router)
    # Without a bucket, serve uploaded photos from disk (development). With one, the bucket or its CDN serves them.
    if not settings.s3_private_bucket:
        app.include_router(private_media.router)
    if not settings.s3_bucket:
        app.mount("/media", StaticFiles(directory=settings.media_dir), name="media")
    # Support console: a static page that talks to the same staff-only API; the page itself holds no data.
    app.mount("/admin", StaticFiles(directory=Path(__file__).parent / "admin", html=True), name="admin")
    app.add_middleware(CompressText)
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"],
                           allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])
    return app
