"""Each side's orders and offers, a shop's listings and a user's favourites indexed for paging by id

Revision ID: a3c7e1f5b820
Revises: f2a6d8b4c013
Create Date: 2026-10-21 01:30:00

"""
from typing import Sequence, Union

from alembic import op


revision: str = 'a3c7e1f5b820'
down_revision: Union[str, None] = 'f2a6d8b4c013'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# (table, column, the index on that column alone, which the new one replaces because it leads with that column)
PAGED = [('orders', 'buyer_id', 'ix_orders_buyer_id'), ('orders', 'seller_id', 'ix_orders_seller_id'),
         ('offers', 'buyer_id', 'ix_offers_buyer_id'), ('offers', 'seller_id', 'ix_offers_seller_id'),
         ('listings', 'seller_id', 'ix_listings_seller_id')]


def upgrade() -> None:
    # Each new index is made before the old one goes, so the lists are never read without one.
    for table, column, old in PAGED:
        op.create_index(f'ix_{table}_{column}_id', table, [column, 'id'])
        op.drop_index(old, table)
    op.create_index('ix_favorites_user_id_id', 'favorites', ['user_id', 'id'])


def downgrade() -> None:
    op.drop_index('ix_favorites_user_id_id', 'favorites')
    for table, column, old in reversed(PAGED):
        op.create_index(old, table, [column])
        op.drop_index(f'ix_{table}_{column}_id', table)
