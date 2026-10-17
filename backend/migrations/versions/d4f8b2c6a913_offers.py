"""price offers

Revision ID: d4f8b2c6a913
Revises: c1e7a4b9d250
Create Date: 2026-10-17 07:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd4f8b2c6a913'
down_revision: Union[str, None] = 'c1e7a4b9d250'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'offers',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('listing_id', sa.Integer(), nullable=False),
        sa.Column('size_id', sa.Integer(), nullable=False),
        sa.Column('buyer_id', sa.Integer(), nullable=False),
        sa.Column('seller_id', sa.Integer(), nullable=False),
        sa.Column('amount_tiyn', sa.BigInteger(), nullable=False),
        sa.Column('counter_tiyn', sa.BigInteger(), nullable=True),
        sa.Column('status', sa.String(length=12), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('order_id', sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(['listing_id'], ['listings.id'], ),
        sa.ForeignKeyConstraint(['size_id'], ['listing_sizes.id'], ),
        sa.ForeignKeyConstraint(['buyer_id'], ['users.id'], ),
        sa.ForeignKeyConstraint(['seller_id'], ['users.id'], ),
        sa.ForeignKeyConstraint(['order_id'], ['orders.id'], ),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_offers_listing_id', 'offers', ['listing_id'])
    op.create_index('ix_offers_buyer_id', 'offers', ['buyer_id'])
    op.create_index('ix_offers_seller_id', 'offers', ['seller_id'])


def downgrade() -> None:
    op.drop_index('ix_offers_seller_id', 'offers')
    op.drop_index('ix_offers_buyer_id', 'offers')
    op.drop_index('ix_offers_listing_id', 'offers')
    op.drop_table('offers')
