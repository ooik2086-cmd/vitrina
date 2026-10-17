"""seller away

Revision ID: b8d4f0a2e593
Revises: a7c3e9f1d482
Create Date: 2026-10-17 11:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b8d4f0a2e593'
down_revision: Union[str, None] = 'a7c3e9f1d482'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.add_column(sa.Column('away_until', sa.Date(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.drop_column('away_until')
