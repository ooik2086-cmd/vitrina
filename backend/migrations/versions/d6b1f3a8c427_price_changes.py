"""Price history, for honest crossed-out prices

Revision ID: d6b1f3a8c427
Revises: c4a9e2f7b316
Create Date: 2026-10-19 12:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd6b1f3a8c427'
down_revision: Union[str, None] = 'c4a9e2f7b316'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'price_changes',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('listing_id', sa.Integer(), sa.ForeignKey('listings.id'), nullable=False),
        sa.Column('price_tiyn', sa.BigInteger(), nullable=False),
        sa.Column('at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_price_changes_listing_id', 'price_changes', ['listing_id'])
    # Existing listings start their history at today's price.
    op.execute("INSERT INTO price_changes (listing_id, price_tiyn, at) "
               "SELECT id, price_tiyn, CURRENT_TIMESTAMP FROM listings")


def downgrade() -> None:
    op.drop_index('ix_price_changes_listing_id', table_name='price_changes')
    op.drop_table('price_changes')
