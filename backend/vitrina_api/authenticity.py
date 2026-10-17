"""Proof that a pair is genuine: the seller uploads a receipt, a box label or a tag, staff look at it.

Proof photos can carry a name, a card's last digits or a shop address, so they never appear on the listing:
only the seller who uploaded them and staff can list them. The listing shows just the outcome.
"""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, File, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from vitrina_core.catalog import Authenticity

from . import services
from .deps import current_user, get_db, get_storage, staff_user
from .errors import ApiError
from .models import AuthProof, Listing, User
from .storage import MAX_UPLOAD_BYTES, Storage, normalize_image

router = APIRouter(prefix="/api/v1")

MAX_PROOFS = 4
UNVERIFIED, SELLER_EVIDENCE = Authenticity.UNVERIFIED.value, Authenticity.SELLER_EVIDENCE.value


def proofs_out(db: Session, listing: Listing) -> dict:
    rows = db.scalars(select(AuthProof).where(AuthProof.listing_id == listing.id).order_by(AuthProof.id)).all()
    return {"authenticity": listing.authenticity, "note": listing.authenticity_note,
            "proofs": [{"id": p.id, "url": p.url} for p in rows]}


def seller_listing(db: Session, listing_id: int, user: User) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None or listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    if listing.status == "hidden":
        raise ApiError(409, "invalid_status")
    return listing


@router.get("/listings/{listing_id}/proofs")
def list_proofs(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    if listing is None or (listing.seller_id != user.id and user.role not in ("support", "admin")):
        raise ApiError(404, "not_found")
    return proofs_out(db, listing)


@router.post("/listings/{listing_id}/proofs", status_code=201)
def add_proof(listing_id: int, file: UploadFile = File(...), user: User = Depends(current_user),
                    db: Session = Depends(get_db), storage: Storage = Depends(get_storage)):
    listing = seller_listing(db, listing_id, user)
    count = len(db.scalars(select(AuthProof.id).where(AuthProof.listing_id == listing.id)).all())
    if count >= MAX_PROOFS:
        raise ApiError(409, "proof_limit")
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(413, "file_too_large")
    db.add(AuthProof(listing_id=listing.id, url=storage.put(normalize_image(data), owner_id=user.id)))
    if listing.authenticity == UNVERIFIED:
        listing.authenticity, listing.authenticity_note = SELLER_EVIDENCE, None  # staff will take a look
    db.commit()
    return proofs_out(db, listing)


@router.delete("/listings/{listing_id}/proofs/{proof_id}")
def delete_proof(listing_id: int, proof_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = seller_listing(db, listing_id, user)
    proof = db.get(AuthProof, proof_id)
    if proof is None or proof.listing_id != listing.id:
        raise ApiError(404, "not_found")
    db.delete(proof)
    db.flush()
    left = db.scalar(select(AuthProof.id).where(AuthProof.listing_id == listing.id))
    if left is None and listing.authenticity == SELLER_EVIDENCE:
        listing.authenticity = UNVERIFIED  # nothing left to back the claim
    db.commit()
    return proofs_out(db, listing)


@router.get("/admin/authenticity")
def admin_authenticity(staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Listings with proof waiting for staff, oldest first."""
    rows = db.scalars(select(Listing).where(Listing.authenticity == SELLER_EVIDENCE,
                                            Listing.status.in_(("published", "paused", "sold", "moderation")))
                      .order_by(Listing.id)).all()
    items = []
    for listing in rows:
        seller = db.get(User, listing.seller_id)
        cover = next((m.processed_url or m.original_url for m in listing.media if m.angle != "frame"), None)
        items.append({"id": listing.id, "title": listing.title, "brand": listing.brand,
                      "model_name": listing.model_name, "price_tiyn": listing.price_tiyn, "cover": cover,
                      "shop_name": seller.shop_name, **proofs_out(db, listing)})
    return {"items": items}


class AuthenticityIn(BaseModel):
    value: Literal["documented", "verified", "unverified"]
    note: str | None = Field(default=None, max_length=500)


DECISION_TEXT = {
    "documented": ("«{t}»: құжаттарыңыз тексерілді, тауарда «Құжаты бар» белгісі тұр.",
                   "«{t}»: документы проверены, у товара отметка «Есть документы».",
                   "“{t}”: your documents were checked; the listing now shows “Documented”."),
    "verified": ("«{t}»: түпнұсқалығы тексерілді, тауарда «Тексерілген» белгісі тұр.",
                 "«{t}»: подлинность проверена, у товара отметка «Проверено».",
                 "“{t}”: authenticity was checked; the listing now shows “Verified”."),
    "unverified": ("«{t}»: дәлел жеткіліксіз. {n}", "«{t}»: доказательств недостаточно. {n}",
                   "“{t}”: not enough proof. {n}"),
}


@router.post("/admin/listings/{listing_id}/authenticity")
def set_authenticity(listing_id: int, body: AuthenticityIn, staff: User = Depends(staff_user),
                     db: Session = Depends(get_db)):
    listing = db.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found")
    note = (body.note or "").strip() or None
    if body.value == "unverified" and (note is None or len(note) < 3):
        raise ApiError(422, "reason_required")
    if body.value != "unverified" and db.scalar(select(AuthProof.id).where(AuthProof.listing_id == listing.id)) is None:
        raise ApiError(409, "invalid_status", "no proof to check")
    listing.authenticity, listing.authenticity_note = body.value, note if body.value == "unverified" else None
    services.audit(db, staff.id, "set_authenticity", f"listing:{listing.id}", f"{body.value}: {note or ''}".strip())
    kk, ru, en = DECISION_TEXT[body.value]
    services.notify(db, listing.seller_id, "authenticity", kk.format(t=listing.title, n=note or ""),
                    ru.format(t=listing.title, n=note or ""), en.format(t=listing.title, n=note or ""),
                    listing_id=listing.id)
    db.commit()
    return proofs_out(db, listing)
