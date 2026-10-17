"""listing daily views

Revision ID: b6d2f9a47c18
Revises: a3c8e5f20b91
Create Date: 2026-10-17 04:10:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b6d2f9a47c18'
down_revision: Union[str, None] = 'a3c8e5f20b91'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'listing_daily_views',
        sa.Column('listing_id', sa.Integer(), nullable=False),
        sa.Column('day', sa.Date(), nullable=False),
        sa.Column('views', sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(['listing_id'], ['listings.id'], ),
        sa.PrimaryKeyConstraint('listing_id', 'day'),
    )


def downgrade() -> None:
    op.drop_table('listing_daily_views')
