"""Photos the cut-out model found no shoe in

Revision ID: d4f8a2c6e917
Revises: c8e2f4a6b913
Create Date: 2026-10-19 16:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd4f8a2c6e917'
down_revision: Union[str, None] = 'c8e2f4a6b913'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('media', schema=None) as batch_op:
        batch_op.add_column(sa.Column('no_cutout', sa.String(length=100), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('media', schema=None) as batch_op:
        batch_op.drop_column('no_cutout')
