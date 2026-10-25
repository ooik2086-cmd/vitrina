"""Seller payouts: what the platform owes a seller after completed orders goes to their bank account.

Until a payment partner sends money by API, support pays each request by bank transfer and marks it paid with the
bank's payment order number. The ledger moves the amount out of the seller's balance as soon as they ask, so the
same money cannot be asked for twice; a request support sends back returns it.
"""
from __future__ import annotations

import re
from datetime import timedelta

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from vitrina_core.money import PROVIDER_CLEARING, Entry, format_tenge, seller_payable

from . import services
from .deps import current_user, get_db, now_utc, staff_user
from .errors import ApiError
from .models import Payout, PayoutAccount, User

router = APIRouter(prefix="/api/v1")

MIN_PAYOUT_TIYN = 100_000  # 1 000 ₸: below that a bank transfer costs more than it is worth
# New bank details wait this long before money goes to them, and the seller is told at once: someone with the
# seller's unlocked phone (or sign-in) cannot put in their own account and take the balance before she sees it.
NEW_ACCOUNT_WAIT = timedelta(hours=24)
IBAN = re.compile(r"^KZ\d{2}[0-9A-Z]{16}$")


def in_flight(payout_id: int) -> str:
    """Ledger account for money that left the seller's balance and is on its way to their bank."""
    return f"payout:{payout_id}"


def clean_iban(raw: str) -> str:
    return re.sub(r"\s+", "", raw).upper()


def iban_ok(iban: str) -> bool:
    """A Kazakh IBAN: KZ, two check digits, 16 characters, and the ISO 13616 mod-97 check."""
    if not IBAN.match(iban):
        return False
    digits = "".join(str(int(c, 36)) for c in iban[4:] + iban[:4])
    return int(digits) % 97 == 1


def tax_id_ok(value: str) -> bool:
    """A Kazakh IIN (person) or BIN (company): 12 digits, the last a check digit over the first 11."""
    if not re.fullmatch(r"\d{12}", value):
        return False
    d = [int(c) for c in value]
    check = sum(d[i] * (i + 1) for i in range(11)) % 11
    if check == 10:
        check = sum(d[i] * w for i, w in enumerate((3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2))) % 11
        if check == 10:
            return False
    return check == d[11]


def masked(iban: str) -> str:
    return f"{iban[:4]} •••• {iban[-4:]}"


def account_out(a: PayoutAccount) -> dict:
    return {"holder_name": a.holder_name, "iban": a.iban, "iban_masked": masked(a.iban), "tax_id": a.tax_id}


def payout_out(p: Payout) -> dict:
    return {"id": p.id, "amount_tiyn": p.amount_tiyn, "status": p.status, "iban_masked": masked(p.iban),
            "created_at": services.aware(p.created_at).isoformat(),
            "decided_at": services.aware(p.decided_at).isoformat() if p.decided_at else None,
            "bank_ref": p.bank_ref, "reason": p.reason}


def open_payout(db: Session, seller_id: int) -> Payout | None:
    return db.scalar(select(Payout).where(Payout.seller_id == seller_id, Payout.status == "requested"))


def seller_only(user: User) -> None:
    if not user.is_seller:
        raise ApiError(403, "seller_required")


class AccountIn(BaseModel):
    holder_name: str = Field(min_length=2, max_length=120)
    iban: str = Field(max_length=40)
    tax_id: str = Field(max_length=20)


class PayoutIn(BaseModel):
    amount_tiyn: int | None = Field(default=None, gt=0)  # None asks for everything owed


class PaidIn(BaseModel):
    bank_ref: str = Field(min_length=1, max_length=60)


class RejectIn(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


@router.get("/me/payout-account")
def get_account(user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller_only(user)
    a = db.get(PayoutAccount, user.id)
    return {"account": account_out(a) if a else None}


@router.put("/me/payout-account")
def put_account(body: AccountIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller_only(user)
    iban, tax_id, name = clean_iban(body.iban), re.sub(r"\D", "", body.tax_id), " ".join(body.holder_name.split())
    if not iban_ok(iban):
        raise ApiError(422, "invalid_iban")
    if not tax_id_ok(tax_id):
        raise ApiError(422, "invalid_tax_id")
    a = db.get(PayoutAccount, user.id)
    if a is None:
        a = PayoutAccount(seller_id=user.id)
        db.add(a)
    if (a.iban, a.tax_id) != (iban, tax_id):  # the name alone (a typo put right) needs no wait
        a.updated_at = now_utc()
        services.notify(
            db, user.id, "payout",
            f"Банк шоты сақталды: {masked(iban)}. Ақшаны 24 сағаттан кейін шығаруға болады. Бұны сіз жасамаған "
            "болсаңыз, қолдау қызметіне бірден жазыңыз.",
            f"Банковский счёт сохранён: {masked(iban)}. Вывести деньги можно через 24 часа. Если это были не вы, "
            "сразу напишите в поддержку.",
            f"Bank account saved: {masked(iban)}. Money can be paid out to it after 24 hours. If this was not you, "
            "write to support at once.")
    a.holder_name, a.iban, a.tax_id = name, iban, tax_id
    services.audit(db, user.id, "payout_account", f"user:{user.id}", masked(iban))
    db.commit()
    return {"account": account_out(a)}


@router.get("/me/payouts")
def my_payouts(user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller_only(user)
    rows = db.scalars(select(Payout).where(Payout.seller_id == user.id).order_by(Payout.id.desc()).limit(50)).all()
    account = db.get(PayoutAccount, user.id)
    return {"payable_tiyn": services.balance(db, seller_payable(str(user.id))), "min_tiyn": MIN_PAYOUT_TIYN,
            "has_account": account is not None, "iban_masked": masked(account.iban) if account else None,
            # When new bank details may first be paid to; null once they may.
            "ready_at": ready.isoformat() if account and (ready := services.aware(account.updated_at)
                                                            + NEW_ACCOUNT_WAIT) > now_utc() else None,
            "open": any(p.status == "requested" for p in rows), "items": [payout_out(p) for p in rows]}


@router.post("/me/payouts", status_code=201)
def request_payout(body: PayoutIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    seller_only(user)
    # The account row is locked until commit, so two taps (or two phones) cannot both pass the checks below and
    # pay out the same balance twice.
    account = db.scalar(select(PayoutAccount).where(PayoutAccount.seller_id == user.id).with_for_update())
    if account is None:
        raise ApiError(409, "payout_account_required")
    if services.aware(account.updated_at) > now_utc() - NEW_ACCOUNT_WAIT:
        raise ApiError(409, "payout_account_new")
    if open_payout(db, user.id) is not None:
        raise ApiError(409, "payout_open")
    owed = services.balance(db, seller_payable(str(user.id)))
    amount = owed if body.amount_tiyn is None else body.amount_tiyn
    if amount > owed:
        raise ApiError(422, "payout_exceeds")
    if amount < MIN_PAYOUT_TIYN:
        raise ApiError(422, "payout_too_small")
    p = Payout(seller_id=user.id, amount_tiyn=amount, holder_name=account.holder_name, iban=account.iban,
               tax_id=account.tax_id, created_at=now_utc())
    db.add(p)
    db.flush()
    services.post_tx(db, key=f"payout:{p.id}:request", order_id=None, kind="payout_requested",
                     entries=[Entry(seller_payable(str(user.id)), debit=amount), Entry(in_flight(p.id), credit=amount)],
                     actor=f"seller:{user.id}")
    db.commit()
    return payout_out(p)


# ---------------------------------------------------------------- staff
def staff_payout_out(db: Session, p: Payout) -> dict:
    seller = db.get(User, p.seller_id)
    return {**payout_out(p), "seller_id": p.seller_id, "shop_name": seller.shop_name if seller else None,
            "phone": seller.phone if seller else None,
            "holder_name": p.holder_name, "iban": p.iban, "tax_id": p.tax_id}


def requested(db: Session, payout_id: int) -> Payout:
    p = db.get(Payout, payout_id, with_for_update=True, populate_existing=True)
    if p is None:
        raise ApiError(404, "not_found")
    if p.status != "requested":
        raise ApiError(409, "payout_decided")
    return p


@router.get("/admin/payouts")
def admin_payouts(status: str = "requested", staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    """Oldest request first, so nobody waits longest for their money."""
    rows = db.scalars(select(Payout).where(Payout.status == status).order_by(Payout.id).limit(200)).all()
    return {"items": [staff_payout_out(db, p) for p in rows]}


@router.post("/admin/payouts/{payout_id}/paid")
def mark_paid(payout_id: int, body: PaidIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    p = requested(db, payout_id)
    services.post_tx(db, key=f"payout:{p.id}:sent", order_id=None, kind="payout_sent",
                     entries=[Entry(in_flight(p.id), debit=p.amount_tiyn),
                              Entry(PROVIDER_CLEARING, credit=p.amount_tiyn)],
                     actor=f"support:{staff.id}", reason=body.bank_ref)
    p.status, p.bank_ref, p.decided_at, p.decided_by = "paid", body.bank_ref.strip(), now_utc(), staff.id
    amount = format_tenge(p.amount_tiyn)
    services.notify(db, p.seller_id, "payout", f"{amount} шотыңызға ({masked(p.iban)}) аударылды.",
                    f"{amount} отправлены на ваш счёт ({masked(p.iban)}).",
                    f"{amount} was sent to your account ({masked(p.iban)}).")
    services.audit(db, staff.id, "payout_paid", f"payout:{p.id}", p.bank_ref)
    db.commit()
    return staff_payout_out(db, p)


@router.post("/admin/payouts/{payout_id}/reject")
def reject(payout_id: int, body: RejectIn, staff: User = Depends(staff_user), db: Session = Depends(get_db)):
    p = requested(db, payout_id)
    services.post_tx(db, key=f"payout:{p.id}:returned", order_id=None, kind="payout_returned",
                     entries=[Entry(in_flight(p.id), debit=p.amount_tiyn),
                              Entry(seller_payable(str(p.seller_id)), credit=p.amount_tiyn)],
                     actor=f"support:{staff.id}", reason=body.reason)
    p.status, p.reason, p.decided_at, p.decided_by = "rejected", body.reason.strip(), now_utc(), staff.id
    services.notify(db, p.seller_id, "payout",
                    f"Ақша шығару сұрауы қайтарылды: {p.reason}. Сома балансыңызға оралды.",
                    f"Запрос на вывод возвращён: {p.reason}. Сумма вернулась на баланс.",
                    f"Your payout request was sent back: {p.reason}. The amount is back in your balance.")
    services.audit(db, staff.id, "payout_rejected", f"payout:{p.id}", p.reason)
    db.commit()
    return staff_payout_out(db, p)
