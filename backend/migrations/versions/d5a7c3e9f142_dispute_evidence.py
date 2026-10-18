"""What the listing said when ordered, and the photos and videos both sides add to a return or dispute

Revision ID: d5a7c3e9f142
Revises: c4f9e2a1b736
Create Date: 2026-10-18 03:00:00

"""
import json
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd5a7c3e9f142'
down_revision: Union[str, None] = 'c4f9e2a1b736'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

DETAILS = ('title', 'brand', 'model_name', 'color', 'category', 'condition', 'defects', 'description')


def upgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('listing_details', sa.Text(), nullable=True))
    op.create_table(
        'order_evidence',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('order_id', sa.Integer(), sa.ForeignKey('orders.id'), nullable=False),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('url', sa.String(length=500), nullable=False),
        sa.Column('kind', sa.String(length=10), nullable=False),
        sa.Column('note', sa.String(length=500), nullable=True),
        sa.Column('client_key', sa.String(length=64), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('order_id', 'user_id', 'client_key', name='uq_order_evidence_key'),
    )
    op.create_index('ix_order_evidence_order_id', 'order_evidence', ['order_id'])
    # Existing orders: the listing as it reads today is the closest record there is, but the seller may have
    # rewritten the description and defects or marked the condition worse since. Such copies say "backfilled", so
    # the app and support show them as today's listing, not as what the buyer read.
    bind = op.get_bind()
    listings = sa.table('listings', sa.column('id'), *[sa.column(c) for c in DETAILS])
    orders = sa.table('orders', sa.column('listing_id'), sa.column('listing_details'))
    for listing_id in bind.execute(sa.select(orders.c.listing_id).distinct()).scalars():
        row = bind.execute(sa.select(listings).where(listings.c.id == listing_id)).first()
        if row is None:
            continue
        details = json.dumps({**{c: getattr(row, c) for c in DETAILS}, 'backfilled': True}, ensure_ascii=False)
        bind.execute(orders.update().where(orders.c.listing_id == listing_id, orders.c.listing_details.is_(None))
                     .values(listing_details=details))


def downgrade() -> None:
    op.drop_index('ix_order_evidence_order_id', table_name='order_evidence')
    op.drop_table('order_evidence')
    with op.batch_alter_table('orders') as batch:
        batch.drop_column('listing_details')
