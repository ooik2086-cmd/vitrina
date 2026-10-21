"""Questions and answers on a listing.

A question asked in public saves the seller from answering the same thing in ten chats ("is it true to size?",
"is the box included?"). Contacts are refused on both sides, as in listings: the deal stays inside VITRINA.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from . import services
from .deps import current_user, get_db, now_utc, optional_user
from .errors import ApiError
from .models import Listing, Question, User, question_waiting
from .social import CONTACT_RE

router = APIRouter(prefix="/api/v1")

OPEN_PER_ASKER = 3  # unanswered questions one buyer may have on one listing


class QuestionIn(BaseModel):
    text: str = Field(min_length=5, max_length=500)


class AnswerIn(BaseModel):
    text: str = Field(min_length=2, max_length=1000)


def clean(text: str) -> str:
    text = " ".join(text.split())
    if CONTACT_RE.search(text):
        raise ApiError(422, "contacts_not_allowed")
    return text


def question_out(q: Question, viewer: User | None) -> dict:
    return {"id": q.id, "text": q.text, "answer": q.answer,
            "asked_at": services.aware(q.created_at).isoformat(),
            "answered_at": services.aware(q.answered_at).isoformat() if q.answered_at else None,
            "mine": viewer is not None and q.asker_id == viewer.id}


def visible_listing(db: Session, listing_id: int) -> Listing:
    listing = db.get(Listing, listing_id)
    if listing is None or listing.status not in ("published", "sold"):
        raise ApiError(404, "not_found")
    return listing


def unanswered_count(db: Session, listing_id: int) -> int:
    """Questions on a listing still waiting for the seller's answer, all of them (the list shows at most 100)."""
    return db.scalar(select(func.count(Question.id)).join(Listing, Listing.id == Question.listing_id)
                     .where(Question.listing_id == listing_id, *question_waiting()))


@router.get("/listings/{listing_id}/questions")
def list_questions(listing_id: int, user: User | None = Depends(optional_user), db: Session = Depends(get_db)):
    listing = visible_listing(db, listing_id)
    seller = user is not None and user.id == listing.seller_id
    q = select(Question).where(Question.listing_id == listing.id, Question.hidden.is_(False))
    if not seller:
        q = q.where(or_(Question.answer.is_not(None), Question.asker_id == (user.id if user else -1)))
    rows = db.scalars(q.order_by(Question.answer.is_(None).desc() if seller else Question.id.desc(),
                                 Question.id.desc()).limit(100)).all()
    return {"items": [question_out(r, user) for r in rows],
            "unanswered": unanswered_count(db, listing.id) if seller else None}


@router.get("/listings/{listing_id}/questions/unanswered")
def count_unanswered(listing_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Only the number, for the seller's edit page: a few bytes on a weak connection, not the whole list."""
    listing = visible_listing(db, listing_id)
    if listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    return {"unanswered": unanswered_count(db, listing.id)}


@router.post("/listings/{listing_id}/questions", status_code=201)
def ask(listing_id: int, body: QuestionIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    listing = visible_listing(db, listing_id)
    if listing.seller_id == user.id:
        raise ApiError(409, "own_listing")
    services.ensure_not_blocked(db, user.id, listing.seller_id)
    text = clean(body.text)
    waiting = db.scalar(select(func.count(Question.id)).where(
        Question.listing_id == listing.id, Question.asker_id == user.id, Question.answer.is_(None),
        Question.hidden.is_(False)))
    if waiting >= OPEN_PER_ASKER:
        raise ApiError(429, "too_many_questions")
    q = Question(listing_id=listing.id, asker_id=user.id, text=text)
    db.add(q)
    services.notify(db, listing.seller_id, "question", f"«{listing.title}» туралы сұрақ: {text}",
                    f"Вопрос о «{listing.title}»: {text}", f"Question about “{listing.title}”: {text}",
                    listing_id=listing.id)
    db.commit()
    return question_out(q, user)


def sellers_question(db: Session, question_id: int, user: User) -> tuple[Question, Listing]:
    q = db.get(Question, question_id)
    listing = db.get(Listing, q.listing_id) if q else None
    if q is None or q.hidden or listing.seller_id != user.id:
        raise ApiError(404, "not_found")
    return q, listing


@router.post("/questions/{question_id}/answer")
def answer(question_id: int, body: AnswerIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Answering again corrects the answer; the asker is told only the first time."""
    q, listing = sellers_question(db, question_id, user)
    first = q.answer is None
    q.answer, q.answered_at = clean(body.text), now_utc()
    if first:
        services.notify(db, q.asker_id, "question_answered", f"Сатушы «{listing.title}» туралы сұрағыңызға жауап берді.",
                        f"Продавец ответил на ваш вопрос о «{listing.title}».",
                        f"The seller answered your question about “{listing.title}”.", listing_id=listing.id)
    db.commit()
    return question_out(q, user)


@router.delete("/questions/{question_id}")
def hide(question_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """The seller can remove an off-topic or rude question; the asker can take back one not yet answered."""
    q = db.get(Question, question_id)
    if q is None or q.hidden:
        raise ApiError(404, "not_found")
    own_unanswered = q.asker_id == user.id and q.answer is None
    if not own_unanswered:
        sellers_question(db, question_id, user)
    q.hidden = True
    db.commit()
    return {"hidden": True}
