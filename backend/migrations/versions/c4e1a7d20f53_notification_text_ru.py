"""notification text in Russian

Revision ID: c4e1a7d20f53
Revises: b9cfd14f46fc
Create Date: 2026-10-17 02:10:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c4e1a7d20f53'
down_revision: Union[str, None] = 'b9cfd14f46fc'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.add_column(sa.Column('text_ru', sa.String(length=300), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.drop_column('text_ru')
