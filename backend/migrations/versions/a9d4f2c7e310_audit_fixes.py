"""Audit fixes: indexes for the catalog, favorites and orders, and the price before a shop sale

Revision ID: a9d4f2c7e310
Revises: f1a8c3e5d702
Create Date: 2026-10-17 19:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a9d4f2c7e310'
down_revision: Union[str, None] = 'f1a8c3e5d702'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('pre_sale_price_tiyn', sa.BigInteger(), nullable=True))
    op.create_index('ix_listings_status_category_price', 'listings', ['status', 'category', 'price_tiyn'])
    op.create_index('ix_listings_status_price', 'listings', ['status', 'price_tiyn'])
    op.create_index('ix_favorites_listing_id', 'favorites', ['listing_id'])
    op.create_index('ix_orders_listing_status', 'orders', ['listing_id', 'status'])
    op.create_index('ix_orders_seller_created', 'orders', ['seller_id', 'created_at'])


def downgrade() -> None:
    op.drop_index('ix_orders_seller_created', 'orders')
    op.drop_index('ix_orders_listing_status', 'orders')
    op.drop_index('ix_favorites_listing_id', 'favorites')
    op.drop_index('ix_listings_status_price', 'listings')
    op.drop_index('ix_listings_status_category_price', 'listings')
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('pre_sale_price_tiyn')
