"""where a listing held by the checks goes back to once its seller fixes it

Revision ID: d8f2a6c4e391
Revises: c4e9a7d2b615
Create Date: 2026-10-22 09:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd8f2a6c4e391'
down_revision: Union[str, None] = 'c4e9a7d2b615'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('held_from', sa.String(length=20), nullable=True))
        batch.add_column(sa.Column('held_for', sa.String(length=200), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('held_for')
        batch.drop_column('held_from')
