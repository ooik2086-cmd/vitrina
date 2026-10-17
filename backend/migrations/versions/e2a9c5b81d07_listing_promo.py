"""listing promo video

Revision ID: e2a9c5b81d07
Revises: c4e1a7d20f53
Create Date: 2026-10-17 02:40:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e2a9c5b81d07'
down_revision: Union[str, None] = 'c4e1a7d20f53'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('promo_state', sa.String(length=12), nullable=True))
        batch_op.add_column(sa.Column('promo_url', sa.String(length=500), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.drop_column('promo_url')
        batch_op.drop_column('promo_state')
