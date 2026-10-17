"""English text on notifications

Revision ID: b8d2f4a6c193
Revises: a3e7c1d9f582
Create Date: 2026-10-18 00:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b8d2f4a6c193'
down_revision: Union[str, None] = 'a3e7c1d9f582'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('notifications') as batch:
        batch.add_column(sa.Column('text_en', sa.String(300), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('notifications') as batch:
        batch.drop_column('text_en')
