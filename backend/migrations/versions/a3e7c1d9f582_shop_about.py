"""seller's words on the shop page

Revision ID: a3e7c1d9f582
Revises: f9d1b5c7e248
Create Date: 2026-10-17 23:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a3e7c1d9f582'
down_revision: Union[str, None] = 'f9d1b5c7e248'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.add_column(sa.Column('shop_about', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.drop_column('shop_about')
