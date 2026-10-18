"""Serves private files from disk when there is no private bucket (development and small installs). A link is
good only with its signature and only until it expires; the bucket's presigned links behave the same way."""
from __future__ import annotations

import hmac
import time

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse

from .errors import ApiError
from .storage import CONTENT_TYPES, KEY_RE, link_signature

router = APIRouter(prefix="/api/v1")


@router.get("/private-media/{owner}/{name}")
def private_file(owner: str, name: str, exp: int, sig: str, request: Request):
    files = request.app.state.private
    key = f"{owner}/{name}"
    if not KEY_RE.fullmatch(key) or exp < time.time() or not hmac.compare_digest(
            sig, link_signature(files.link_secret, key, exp)):
        raise ApiError(404, "not_found")  # an expired or altered link says no more than a missing file
    path = (files.root / key).resolve()
    if files.root.resolve() not in path.parents or not path.is_file():
        raise ApiError(404, "not_found")
    return FileResponse(path, media_type=CONTENT_TYPES[name.rsplit(".", 1)[1]],
                        headers={"Cache-Control": "private, max-age=3600"})
