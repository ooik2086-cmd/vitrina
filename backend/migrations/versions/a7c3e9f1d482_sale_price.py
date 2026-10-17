"""sale price

Revision ID: a7c3e9f1d482
Revises: f2b9d4e7c615
Create Date: 2026-10-17 10:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a7c3e9f1d482'
down_revision: Union[str, None] = 'f2b9d4e7c615'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('was_price_tiyn', sa.BigInteger(), nullable=True))
        batch.add_column(sa.Column('was_until', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('was_until')
        batch.drop_column('was_price_tiyn')
