"""Saved searches can name colours

Revision ID: a3e7c9d1f528
Revises: f2c8a6d4b917
Create Date: 2026-10-19 06:30:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a3e7c9d1f528'
down_revision: Union[str, None] = 'f2c8a6d4b917'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('saved_searches', schema=None) as batch_op:
        batch_op.add_column(sa.Column('color', sa.String(length=300), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('saved_searches', schema=None) as batch_op:
        batch_op.drop_column('color')
