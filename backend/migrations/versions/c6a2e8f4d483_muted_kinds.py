"""user muted notification kinds

Revision ID: c6a2e8f4d483
Revises: b5f1d9e3c372
Create Date: 2026-10-17 18:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c6a2e8f4d483'
down_revision: Union[str, None] = 'b5f1d9e3c372'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.add_column(sa.Column('muted_kinds', sa.String(length=200), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.drop_column('muted_kinds')
