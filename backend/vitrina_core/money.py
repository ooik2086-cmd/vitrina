"""Money in integer tiyn (1 ₸ = 100 tiyn), commission and an append-only ledger.

Ledger rules:
- every transaction is balanced (debits == credits);
- entries are never edited or deleted; a correction is a new reversing
  transaction with a reason and an actor (audit trail);
- the same idempotency key never posts twice.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

TIYN_PER_TENGE = 100


def tenge_to_tiyn(amount: str | int) -> int:
    """Parse '45000' or '45000.50' into tiyn without floats."""
    if isinstance(amount, int):
        return amount * TIYN_PER_TENGE
    text = amount.strip().replace(" ", "").replace(",", ".")
    whole, _, frac = text.partition(".")
    if not whole.isdigit() or (frac and (not frac.isdigit() or len(frac) > 2)):
        raise ValueError(f"invalid tenge amount: {amount!r}")
    return int(whole) * TIYN_PER_TENGE + int(frac.ljust(2, "0") or 0)


def format_tenge(tiyn: int) -> str:
    sign = "-" if tiyn < 0 else ""
    whole, frac = divmod(abs(tiyn), TIYN_PER_TENGE)
    grouped = f"{whole:,}".replace(",", " ")
    return f"{sign}{grouped} ₸" if frac == 0 else f"{sign}{grouped},{frac:02d} ₸"


@dataclass(frozen=True)
class CommissionRule:
    """Rate in basis points (500 = 5%). Kept in config, versioned, never hard-coded."""
    version: str
    rate_bp: int
    min_fee_tiyn: int = 0

    def fee_for(self, item_price_tiyn: int) -> int:
        if item_price_tiyn <= 0:
            raise ValueError("price must be positive")
        # round half up to the nearest tiyn using integers only
        fee = (item_price_tiyn * self.rate_bp + 5_000) // 10_000
        return min(max(fee, self.min_fee_tiyn), item_price_tiyn)


@dataclass(frozen=True)
class Entry:
    account: str
    debit: int = 0
    credit: int = 0


@dataclass(frozen=True)
class Transaction:
    id: int
    idempotency_key: str
    order_id: str
    kind: str
    entries: tuple[Entry, ...]
    actor: str
    reason: str | None
    at: datetime


class LedgerError(Exception):
    pass


def validate_entries(entries: list[Entry]) -> None:
    if not entries:
        raise LedgerError("empty transaction")
    for e in entries:
        if not isinstance(e.debit, int) or not isinstance(e.credit, int):
            raise LedgerError("amounts must be integer tiyn")
        if e.debit < 0 or e.credit < 0 or (e.debit and e.credit):
            raise LedgerError("an entry is either a positive debit or a positive credit")
    if sum(e.debit for e in entries) != sum(e.credit for e in entries):
        raise LedgerError("transaction is not balanced")


class Ledger:
    def __init__(self) -> None:
        self._txs: list[Transaction] = []
        self._by_key: dict[str, Transaction] = {}

    @property
    def transactions(self) -> tuple[Transaction, ...]:
        return tuple(self._txs)

    def post(self, *, idempotency_key: str, order_id: str, kind: str, entries: list[Entry],
             actor: str, reason: str | None = None) -> Transaction:
        if idempotency_key in self._by_key:
            return self._by_key[idempotency_key]
        validate_entries(entries)
        tx = Transaction(len(self._txs) + 1, idempotency_key, order_id, kind, tuple(entries),
                         actor, reason, datetime.now(timezone.utc))
        self._txs.append(tx)
        self._by_key[idempotency_key] = tx
        return tx

    def find(self, idempotency_key: str) -> Transaction | None:
        return self._by_key.get(idempotency_key)

    def balance(self, account: str) -> int:
        """Credit-normal balance (what the platform owes on that account)."""
        return sum(e.credit - e.debit for tx in self._txs for e in tx.entries if e.account == account)

    def reverse(self, tx_id: int, *, actor: str, reason: str) -> Transaction:
        if not reason or not reason.strip():
            raise LedgerError("a reversal needs a reason")
        original = next((t for t in self._txs if t.id == tx_id), None)
        if original is None:
            raise LedgerError(f"transaction {tx_id} not found")
        flipped = [Entry(e.account, debit=e.credit, credit=e.debit) for e in original.entries]
        return self.post(idempotency_key=f"reverse:{tx_id}", order_id=original.order_id,
                         kind=f"reversal:{original.kind}", entries=flipped, actor=actor, reason=reason)


# Account names. `escrow:` is a bookkeeping account mirroring funds the licensed
# provider holds for the order; the platform itself never holds the money.
def escrow(order_id: str) -> str:
    return f"escrow:{order_id}"


def seller_payable(seller_id: str) -> str:
    return f"seller_payable:{seller_id}"


def buyer_refund(buyer_id: str) -> str:
    return f"buyer_refund:{buyer_id}"


PROVIDER_CLEARING = "provider_clearing"
PLATFORM_FEE = "platform_fee_revenue"


def record_payment(ledger: Ledger, *, order_id: str, amount_tiyn: int, provider_event_id: str) -> Transaction:
    return ledger.post(
        idempotency_key=f"payment:{provider_event_id}", order_id=order_id, kind="payment_captured",
        entries=[Entry(PROVIDER_CLEARING, debit=amount_tiyn), Entry(escrow(order_id), credit=amount_tiyn)],
        actor="system")


def settlement_entries(*, order_id: str, seller_id: str, buyer_id: str, held_tiyn: int,
                       item_price_tiyn: int, refund_tiyn: int, rule: CommissionRule) -> tuple[str, list[Entry]]:
    """Split the held amount: refund part (or all) to the buyer, the rest to the seller
    minus commission. Commission is charged only on what the seller keeps."""
    if held_tiyn <= 0:
        raise LedgerError("nothing held for this order")
    if not 0 <= refund_tiyn <= held_tiyn:
        raise LedgerError("refund must be between 0 and the held amount")
    to_seller_gross = held_tiyn - refund_tiyn
    entries = [Entry(escrow(order_id), debit=held_tiyn)]
    if refund_tiyn:
        entries.append(Entry(buyer_refund(buyer_id), credit=refund_tiyn))
    if to_seller_gross:
        fee = rule.fee_for(min(to_seller_gross, item_price_tiyn))
        entries.append(Entry(PLATFORM_FEE, credit=fee))
        entries.append(Entry(seller_payable(seller_id), credit=to_seller_gross - fee))
    kind = "refund_full" if to_seller_gross == 0 else ("completion" if refund_tiyn == 0 else "partial_refund")
    return kind, entries


def settle(ledger: Ledger, *, order_id: str, seller_id: str, buyer_id: str, item_price_tiyn: int,
           refund_tiyn: int, rule: CommissionRule, actor: str, reason: str | None = None) -> Transaction:
    already = ledger.find(f"settle:{order_id}")
    if already is not None:  # a retried request returns the original settlement
        return already
    kind, entries = settlement_entries(order_id=order_id, seller_id=seller_id, buyer_id=buyer_id,
                                       held_tiyn=ledger.balance(escrow(order_id)),
                                       item_price_tiyn=item_price_tiyn, refund_tiyn=refund_tiyn, rule=rule)
    return ledger.post(idempotency_key=f"settle:{order_id}", order_id=order_id, kind=kind,
                       entries=entries, actor=actor, reason=reason)
