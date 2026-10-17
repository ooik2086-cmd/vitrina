"""review fit

Revision ID: d2a6f8c4b715
Revises: c9e5a1b3f604
Create Date: 2026-10-17 13:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd2a6f8c4b715'
down_revision: Union[str, None] = 'c9e5a1b3f604'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('reviews') as batch:
        batch.add_column(sa.Column('fit', sa.String(length=10), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('reviews') as batch:
        batch.drop_column('fit')
