"""Every photo the buyer saw when ordering, so the seller may replace listing photos later

Revision ID: c4f9e2a1b736
Revises: b3e8d1f4a925
Create Date: 2026-10-18 03:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c4f9e2a1b736'
down_revision: Union[str, None] = 'b3e8d1f4a925'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('listing_photos', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.drop_column('listing_photos')
