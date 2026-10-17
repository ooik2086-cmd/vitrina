"""Tip to the seller when a listing has not sold for three weeks

Revision ID: f1a8c3e5d702
Revises: e4c7a9d2b158
Create Date: 2026-10-21 12:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'f1a8c3e5d702'
down_revision: Union[str, None] = 'e4c7a9d2b158'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('stale_nudged_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('stale_nudged_at')
