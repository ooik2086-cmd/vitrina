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
from .storage import LocalStorage


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


def get_storage(request: Request) -> LocalStorage:
    return request.app.state.storage


def current_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User:
    if not authorization or not authorization.startswith("Bearer "):
        raise ApiError(401, "unauthorized")
    token = db.scalar(select(AuthToken).where(AuthToken.token_hash == sha256(authorization[7:].strip())))
    if token is None or token.revoked or services.aware(token.expires_at) < now_utc():
        raise ApiError(401, "unauthorized")
    user = db.get(User, token.user_id)
    if user.is_blocked:
        raise ApiError(403, "forbidden", "account blocked")
    return user


def optional_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User | None:
    if not authorization:
        return None
    return current_user(authorization, db)


def staff_user(user: User = Depends(current_user)) -> User:
    if user.role not in ("support", "admin"):
        raise ApiError(403, "forbidden")
    return user
