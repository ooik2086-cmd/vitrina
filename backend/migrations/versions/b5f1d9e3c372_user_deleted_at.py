"""user deleted_at

Revision ID: b5f1d9e3c372
Revises: a9e3c7f1b268
Create Date: 2026-10-17 17:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b5f1d9e3c372'
down_revision: Union[str, None] = 'a9e3c7f1b268'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.add_column(sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.drop_column('deleted_at')
