"""The 360° frame that matches the cover photo

Revision ID: b5d9e1f3a742
Revises: a3e7c9d1f528
Create Date: 2026-10-19 06:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b5d9e1f3a742'
down_revision: Union[str, None] = 'a3e7c9d1f528'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('cover_frame', sa.String(length=500), nullable=True))
        batch_op.add_column(sa.Column('cover_frame_of', sa.String(length=500), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.drop_column('cover_frame_of')
        batch_op.drop_column('cover_frame')
