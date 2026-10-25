"""Request dependencies shared by every router: database session, settings, storage and the signed-in user."""
from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from fastapi import Depends, Header, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import services
from .config import Settings
from .errors import ApiError
from .models import AuthToken, User
from .storage import Storage


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def get_db(request: Request):
    db = request.app.state.sessions()
    try:
        yield db
    finally:
        db.close()


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_storage(request: Request) -> Storage:
    return request.app.state.storage


def get_private(request: Request) -> Storage:
    """Receipts and dispute evidence: stored apart, shown only through links that expire (storage.private_link)."""
    return request.app.state.private


def current_sign_in(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> AuthToken:
    """The sign-in this request comes with, live and of an account that is not blocked."""
    if not authorization or not authorization.startswith("Bearer "):
        raise ApiError(401, "unauthorized")
    token = db.scalar(select(AuthToken).where(AuthToken.token_hash == sha256(authorization[7:].strip())))
    if token is None or token.revoked or services.aware(token.expires_at) < now_utc():
        raise ApiError(401, "unauthorized")
    user = db.get(User, token.user_id)
    if user.is_blocked:
        raise ApiError(403, "account_blocked")
    return token


def current_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User:
    return db.get(User, current_sign_in(authorization, db).user_id)


def optional_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User | None:
    if not authorization:
        return None
    return current_user(authorization, db)


def staff_user(user: User = Depends(current_user)) -> User:
    if user.role not in ("support", "admin"):
        raise ApiError(403, "forbidden")
    return user
