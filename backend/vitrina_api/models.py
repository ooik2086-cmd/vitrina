"""Database schema (SQLAlchemy 2). SQLite for local runs, PostgreSQL in production.

Money columns are BigInteger tiyn. Ledger rows, order events and audit rows are
insert-only: the application never updates or deletes them.
"""
from __future__ import annotations

from datetime import date, datetime, timezone

from sqlalchemy import (BigInteger, Boolean, Date, DateTime, ForeignKey, Index, Integer, LargeBinary, String, Text,
                        UniqueConstraint, create_engine)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship, sessionmaker


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    phone: Mapped[str] = mapped_column(String(20), unique=True, index=True)
    display_name: Mapped[str | None] = mapped_column(String(60))
    city: Mapped[str | None] = mapped_column(String(60))
    role: Mapped[str] = mapped_column(String(20), default="user")  # user | support | admin
    is_seller: Mapped[bool] = mapped_column(Boolean, default=False)
    shop_name: Mapped[str | None] = mapped_column(String(80))
    is_blocked: Mapped[bool] = mapped_column(Boolean, default=False)
    away_until: Mapped[date | None] = mapped_column(Date)  # seller on holiday: no new orders through this day
    last_delivery: Mapped[str | None] = mapped_column(Text)  # JSON of the address last ordered to, to prefill
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # the person deleted the account
    muted_kinds: Mapped[str | None] = mapped_column(String(200))  # comma-separated optional alerts turned off
    shop_about: Mapped[str | None] = mapped_column(Text)  # the seller's own words on the shop page: returns, hours
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class OtpCode(Base):
    __tablename__ = "otp_codes"
    id: Mapped[int] = mapped_column(primary_key=True)
    phone: Mapped[str] = mapped_column(String(20), index=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    used: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class AuthToken(Base):
    __tablename__ = "auth_tokens"
    id: Mapped[int] = mapped_column(primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)


class Listing(Base):
    __tablename__ = "listings"
    # The catalog filters on status first, then category and price, and sorts by price or by newest.
    __table_args__ = (Index("ix_listings_status_category_price", "status", "category", "price_tiyn"),
                      Index("ix_listings_status_price", "status", "price_tiyn"))
    id: Mapped[int] = mapped_column(primary_key=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    status: Mapped[str] = mapped_column(String(20), default="draft", index=True)  # draft|moderation|published|paused|sold|hidden|rejected|archived
    title: Mapped[str] = mapped_column(String(120))
    category: Mapped[str] = mapped_column(String(30), index=True)
    brand: Mapped[str | None] = mapped_column(String(60), index=True)
    model_name: Mapped[str | None] = mapped_column(String(80))
    color: Mapped[str] = mapped_column(String(40))
    condition: Mapped[str] = mapped_column(String(30))
    authenticity: Mapped[str] = mapped_column(String(30), default="unverified")
    authenticity_note: Mapped[str | None] = mapped_column(Text)  # why staff did not accept the proof
    defects: Mapped[str | None] = mapped_column(Text)
    description: Mapped[str | None] = mapped_column(Text)
    price_tiyn: Mapped[int] = mapped_column(BigInteger)
    delivery_price_tiyn: Mapped[int] = mapped_column(BigInteger, default=0)
    showcase_style: Mapped[str] = mapped_column(String(20), default="clean")
    # light | dark: the backdrop the cut-out shoe stands out on (a dark shoe gets a light one); None without a cut-out
    backdrop: Mapped[str | None] = mapped_column(String(10))
    # The 360° frame (its original_url) that shows the shoe as the cover photo does, and that cover's original_url:
    # a turn starts there. Chosen by the seller or matched by the media job; a new cover, or removing that frame,
    # voids it.
    cover_frame: Mapped[str | None] = mapped_column(String(500))
    cover_frame_of: Mapped[str | None] = mapped_column(String(500))
    # JSON {side: {"frame": original_url, "of": the side photo's original_url}} for the outer, front, inner and back
    # photos: the 360° frame of one turn showing that side square on. It tells which way and how evenly the turn
    # goes, so shoes compared side by side turn alike. Matched by the media job; a new photo voids its side.
    angle_frames: Mapped[str | None] = mapped_column(Text)
    search_text: Mapped[str] = mapped_column(Text, default="")
    views: Mapped[int] = mapped_column(Integer, default=0, server_default="0")  # product page opens by others
    promo_state: Mapped[str | None] = mapped_column(String(12))  # rendering | ready | failed; None = never made
    promo_url: Mapped[str | None] = mapped_column(String(500))
    # Automatic publish checks (see moderation.py): what they flagged, what staff already cleared, and the
    # reason staff gave when sending a listing back. Codes are comma-separated.
    moderation_flags: Mapped[str | None] = mapped_column(String(200))
    moderation_cleared: Mapped[str | None] = mapped_column(String(200))
    moderation_note: Mapped[str | None] = mapped_column(Text)
    # The price before the seller's last cut, shown crossed out for a while. Only a price the listing really had.
    was_price_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    was_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    announced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # saved-search alerts sent
    stale_nudged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # 'not selling' tip sent
    # The seller's own price before a shop-wide sale, put back when the sale ends (the crossed-out price may differ).
    pre_sale_price_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    # selectin: a page of listings loads all their sizes and photos in one query each, not two per listing.
    sizes: Mapped[list[ListingSize]] = relationship(cascade="all, delete-orphan", order_by="ListingSize.id",
                                                    lazy="selectin")
    media: Mapped[list[Media]] = relationship(cascade="all, delete-orphan", order_by="Media.position",
                                              lazy="selectin")


class ListingSize(Base):
    __tablename__ = "listing_sizes"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    label: Mapped[str] = mapped_column(String(20))       # as written on the shoe, e.g. "EU 42"
    insole_mm: Mapped[int] = mapped_column(Integer)      # insole length measured by the seller, e.g. 265
    quantity: Mapped[int] = mapped_column(Integer, default=1)


class Media(Base):
    __tablename__ = "media"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    original_url: Mapped[str] = mapped_column(String(500))
    processed_url: Mapped[str | None] = mapped_column(String(500))
    # A small copy (480 px) of processed_url or original_url, shown while the showcase is being scrolled.
    thumb_url: Mapped[str | None] = mapped_column(String(500))
    angle: Mapped[str] = mapped_column(String(20))  # front|outer|inner|back|top|sole|detail|label|defect|frame
    position: Mapped[int] = mapped_column(Integer, default=0)
    phash: Mapped[str | None] = mapped_column(String(16), index=True)  # difference hash, for reused photos


class Favorite(Base):
    __tablename__ = "favorites"
    __table_args__ = (UniqueConstraint("user_id", "listing_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)  # "saved by N" on every page


class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (Index("ix_orders_listing_status", "listing_id", "status"),
                      Index("ix_orders_seller_created", "seller_id", "created_at"))
    id: Mapped[int] = mapped_column(primary_key=True)
    buyer_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"))
    size_id: Mapped[int] = mapped_column(ForeignKey("listing_sizes.id"))
    # What the buyer ordered, as shown at that moment: the seller may later improve the listing's name or photos.
    listing_title: Mapped[str | None] = mapped_column(String(120))
    listing_cover: Mapped[str | None] = mapped_column(String(500))
    # JSON list of {"url", "angle"}: every photo and 360° frame the listing had when the order was placed. The seller
    # may replace photos later; this is what the buyer chose, shown to both sides and to support in a dispute.
    # The orphan sweep (orphans.py) reads this column too, so files listed here are never removed.
    listing_photos: Mapped[str | None] = mapped_column(Text)
    # JSON of what the listing said when ordered (brand, model, colour, condition, defects, description): the
    # seller may still mark the condition worse or rewrite the text later.
    listing_details: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(40), index=True)
    item_price_tiyn: Mapped[int] = mapped_column(BigInteger)
    delivery_price_tiyn: Mapped[int] = mapped_column(BigInteger)
    commission_version: Mapped[str] = mapped_column(String(40))
    tracking_number: Mapped[str | None] = mapped_column(String(60))
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    pending_refund_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    dispute_reason: Mapped[str | None] = mapped_column(Text)
    # Where the pair goes. The seller sees it only once the order is paid.
    recipient_name: Mapped[str | None] = mapped_column(String(80))
    recipient_phone: Mapped[str | None] = mapped_column(String(16))
    delivery_city: Mapped[str | None] = mapped_column(String(60))
    delivery_address: Mapped[str | None] = mapped_column(String(200))
    delivery_note: Mapped[str | None] = mapped_column(String(200))
    # A seller's promo code takes its discount off item_price_tiyn, so the seller alone pays for it.
    promo_code_id: Mapped[int | None] = mapped_column(ForeignKey("promo_codes.id"), index=True)
    promo_code: Mapped[str | None] = mapped_column(String(20))
    promo_discount_tiyn: Mapped[int] = mapped_column(BigInteger, default=0, server_default="0")
    # Set when the buyer got the one "how were they?" reminder, so it never comes twice.
    review_reminded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class PriceChange(Base):
    """Every price a listing has had, from when it was set. The crossed-out price on a sale is the lowest of the
    last 30 days, so raising a price just to cut it shows no discount."""
    __tablename__ = "price_changes"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    price_tiyn: Mapped[int] = mapped_column(BigInteger)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class PayoutAccount(Base):
    """Where a seller's money goes: the account holder, a Kazakh IBAN and the holder's IIN or BIN."""
    __tablename__ = "payout_accounts"
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    holder_name: Mapped[str] = mapped_column(String(120))
    iban: Mapped[str] = mapped_column(String(20))
    tax_id: Mapped[str] = mapped_column(String(12))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Payout(Base):
    """A seller's request to send what the platform owes them to their bank. The bank details are copied in, so
    a later change of account cannot redirect a request support already checked."""
    __tablename__ = "payouts"
    id: Mapped[int] = mapped_column(primary_key=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    amount_tiyn: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(10), default="requested", index=True)  # requested|paid|rejected
    holder_name: Mapped[str] = mapped_column(String(120))
    iban: Mapped[str] = mapped_column(String(20))
    tax_id: Mapped[str] = mapped_column(String(12))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decided_by: Mapped[int | None] = mapped_column(Integer)
    bank_ref: Mapped[str | None] = mapped_column(String(60))  # the bank's payment order number
    reason: Mapped[str | None] = mapped_column(Text)          # why support sent it back


class ListingDailyViews(Base):
    """Product page opens by others, per listing and Almaty calendar day, for the seller's charts."""
    __tablename__ = "listing_daily_views"
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    views: Mapped[int] = mapped_column(Integer, default=0)


class OrderEvent(Base):
    __tablename__ = "order_events"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    actor: Mapped[str] = mapped_column(String(20))
    actor_user_id: Mapped[int | None] = mapped_column(Integer)
    from_status: Mapped[str] = mapped_column(String(40))
    to_status: Mapped[str] = mapped_column(String(40))
    reason: Mapped[str | None] = mapped_column(Text)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class LedgerTx(Base):
    __tablename__ = "ledger_transactions"
    id: Mapped[int] = mapped_column(primary_key=True)
    idempotency_key: Mapped[str] = mapped_column(String(120), unique=True)
    order_id: Mapped[int | None] = mapped_column(Integer, index=True)
    kind: Mapped[str] = mapped_column(String(40))
    actor: Mapped[str] = mapped_column(String(60))
    reason: Mapped[str | None] = mapped_column(Text)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    entries: Mapped[list[LedgerEntry]] = relationship(cascade="all")


class LedgerEntry(Base):
    __tablename__ = "ledger_entries"
    id: Mapped[int] = mapped_column(primary_key=True)
    tx_id: Mapped[int] = mapped_column(ForeignKey("ledger_transactions.id"), index=True)
    account: Mapped[str] = mapped_column(String(80), index=True)
    debit: Mapped[int] = mapped_column(BigInteger, default=0)
    credit: Mapped[int] = mapped_column(BigInteger, default=0)


class WebhookEvent(Base):
    __tablename__ = "webhook_events"
    __table_args__ = (UniqueConstraint("source", "event_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(30))
    event_id: Mapped[str] = mapped_column(String(120))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class IdempotencyRecord(Base):
    __tablename__ = "idempotency_records"
    __table_args__ = (UniqueConstraint("user_id", "scope", "key"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(Integer)
    scope: Mapped[str] = mapped_column(String(40))
    key: Mapped[str] = mapped_column(String(100))
    order_id: Mapped[int] = mapped_column(Integer)


class AuditLog(Base):
    __tablename__ = "audit_log"
    id: Mapped[int] = mapped_column(primary_key=True)
    actor_user_id: Mapped[int | None] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(60))
    target: Mapped[str] = mapped_column(String(80))
    reason: Mapped[str | None] = mapped_column(Text)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class ListingEmbedding(Base):
    """Search-by-photo vector of a listing's main photo (see visual.py). Rebuilt when the model changes."""
    __tablename__ = "listing_embeddings"
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), primary_key=True)
    model: Mapped[str] = mapped_column(String(40))
    vector: Mapped[bytes] = mapped_column(LargeBinary)  # float32, little-endian
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class ListingReport(Base):
    """A buyer's complaint about a listing; one open report per person per listing."""
    __tablename__ = "listing_reports"
    __table_args__ = (UniqueConstraint("listing_id", "reporter_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    reporter_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    reason: Mapped[str] = mapped_column(String(30))  # fake | wrong_photos | prohibited | contact_details | other
    text: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), default="open", index=True)  # open | hidden | dismissed
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Conversation(Base):
    """One thread per buyer and listing; the seller is fixed by the listing."""
    __tablename__ = "conversations"
    __table_args__ = (UniqueConstraint("listing_id", "buyer_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    buyer_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    buyer_last_read_id: Mapped[int] = mapped_column(Integer, default=0)
    seller_last_read_id: Mapped[int] = mapped_column(Integer, default=0)
    last_message_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Message(Base):
    __tablename__ = "messages"
    id: Mapped[int] = mapped_column(primary_key=True)
    conversation_id: Mapped[int] = mapped_column(ForeignKey("conversations.id"), index=True)
    sender_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    body: Mapped[str] = mapped_column(Text)  # may be empty when the message is a photo
    photo_url: Mapped[str | None] = mapped_column(String(500))
    # Set when the text looks like a phone number or link: the other side sees a reminder to pay only in the app.
    contact_warning: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class OrderEvidence(Base):
    """A photo or short video a buyer or seller adds to a return or dispute. Never edited or removed: support
    decides on what both sides showed, and both sides see the same."""
    __tablename__ = "order_evidence"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    url: Mapped[str] = mapped_column(String(500))
    kind: Mapped[str] = mapped_column(String(10))  # photo | video
    note: Mapped[str | None] = mapped_column(String(500))
    client_key: Mapped[str | None] = mapped_column(String(64))  # the app's id for the file, so a retry adds no copy
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    __table_args__ = (UniqueConstraint("order_id", "user_id", "client_key", name="uq_order_evidence_key"),)


class Review(Base):
    """A buyer's review of a seller, allowed once per completed order."""
    __tablename__ = "reviews"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), unique=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    buyer_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    rating: Mapped[int] = mapped_column(Integer)
    text: Mapped[str | None] = mapped_column(Text)
    seller_reply: Mapped[str | None] = mapped_column(Text)
    photos: Mapped[str | None] = mapped_column(Text)  # JSON list of the buyer's own photos of what arrived
    fit: Mapped[str | None] = mapped_column(String(10))  # "small", "true" or "large": how the size felt
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class SavedSearch(Base):
    """Catalog filters a buyer asked to be told about: a new listing that matches sends them a notification."""
    __tablename__ = "saved_searches"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    q: Mapped[str | None] = mapped_column(String(100))
    category: Mapped[str | None] = mapped_column(String(30))
    brand: Mapped[str | None] = mapped_column(String(60))
    condition: Mapped[str | None] = mapped_column(String(200))
    min_price_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    max_price_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    size_cm: Mapped[str | None] = mapped_column(String(8))
    color: Mapped[str | None] = mapped_column(String(300))  # stored colour names, comma-separated
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Follow(Base):
    """A buyer following a shop: each new listing from it sends them a notification."""
    __tablename__ = "follows"
    __table_args__ = (UniqueConstraint("user_id", "seller_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class AuthProof(Base):
    """A receipt, box label or tag photo backing a listing's authenticity. Seen only by its seller and staff."""
    __tablename__ = "auth_proofs"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    url: Mapped[str] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class PromoCode(Base):
    """A seller's discount code: a percent or a fixed sum off one pair, each buyer once."""
    __tablename__ = "promo_codes"
    id: Mapped[int] = mapped_column(primary_key=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    code: Mapped[str] = mapped_column(String(20))
    percent: Mapped[int | None] = mapped_column(Integer)
    amount_tiyn: Mapped[int | None] = mapped_column(BigInteger)
    min_price_tiyn: Mapped[int] = mapped_column(BigInteger, default=0)
    max_uses: Mapped[int | None] = mapped_column(Integer)
    ends_on: Mapped[date | None] = mapped_column(Date)  # last day it works, Almaty time
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Question(Base):
    """A public question about a listing. Everyone sees it once the seller has answered; until then only the
    asker and the seller do."""
    __tablename__ = "questions"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    asker_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    text: Mapped[str] = mapped_column(String(500))
    answer: Mapped[str | None] = mapped_column(String(1000))
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    hidden: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Block(Base):
    """One user stops another from writing, offering, asking or ordering from them. Works both ways for
    contact; only the blocker can lift it."""
    __tablename__ = "blocks"
    __table_args__ = (UniqueConstraint("user_id", "blocked_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    blocked_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class StockAlert(Base):
    """A buyer waiting for a sold-out size: told once when it can be ordered again, then the alert is gone."""
    __tablename__ = "stock_alerts"
    __table_args__ = (UniqueConstraint("user_id", "size_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    size_id: Mapped[int] = mapped_column(ForeignKey("listing_sizes.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Offer(Base):
    """A buyer's price offer on one size of a listing. The seller accepts, declines or names their own price;
    an accepted offer lets that buyer order at that price for a limited time."""
    __tablename__ = "offers"
    id: Mapped[int] = mapped_column(primary_key=True)
    listing_id: Mapped[int] = mapped_column(ForeignKey("listings.id"), index=True)
    size_id: Mapped[int] = mapped_column(ForeignKey("listing_sizes.id"))
    buyer_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    seller_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    amount_tiyn: Mapped[int] = mapped_column(BigInteger)          # what the buyer offered
    counter_tiyn: Mapped[int | None] = mapped_column(BigInteger)  # the seller's price, when they countered
    status: Mapped[str] = mapped_column(String(12), default="pending")  # pending|countered|accepted|declined|withdrawn|ordered
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    order_id: Mapped[int | None] = mapped_column(ForeignKey("orders.id"))


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(40))  # order_status | message | review
    text_kk: Mapped[str] = mapped_column(String(300))
    text_ru: Mapped[str | None] = mapped_column(String(300))  # None on notices from before Russian was added
    text_en: Mapped[str | None] = mapped_column(String(300))  # None on notices from before English was added
    order_id: Mapped[int | None] = mapped_column(Integer)
    conversation_id: Mapped[int | None] = mapped_column(Integer)
    listing_id: Mapped[int | None] = mapped_column(Integer)  # e.g. a price drop on a favourite
    read: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


def make_session_factory(database_url: str, *, create_schema: bool = True):
    # A server database: test connections before use (a restarted or failed-over Postgres leaves dead ones in the
    # pool), recycle them before the server's idle timeout, and size the pool for the request threadpool.
    kwargs = ({"connect_args": {"check_same_thread": False}} if database_url.startswith("sqlite")
              else {"pool_pre_ping": True, "pool_recycle": 1800, "pool_size": 10, "max_overflow": 20,
                    "pool_timeout": 10})
    engine = create_engine(database_url, **kwargs)
    if create_schema:
        Base.metadata.create_all(engine)
    return sessionmaker(bind=engine, expire_on_commit=False)
