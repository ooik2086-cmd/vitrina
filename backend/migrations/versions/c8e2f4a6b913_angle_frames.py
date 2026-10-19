"""The 360° frames that show each side photo

Revision ID: c8e2f4a6b913
Revises: b5d9e1f3a742
Create Date: 2026-10-19 09:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c8e2f4a6b913'
down_revision: Union[str, None] = 'b5d9e1f3a742'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('angle_frames', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.drop_column('angle_frames')
