"""A saved search keeps the seller's city the buyer filtered by, as the catalog does

Revision ID: d2a7c5e9b136
Revises: c4f9a1e7d258
Create Date: 2026-10-26 04:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'd2a7c5e9b136'
down_revision: Union[str, None] = 'c4f9a1e7d258'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('saved_searches', sa.Column('city', sa.String(length=60), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('saved_searches') as batch:
        batch.drop_column('city')
