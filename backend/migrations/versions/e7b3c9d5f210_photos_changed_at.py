"""When a listing's photos last changed, for the photo worker's queue

Revision ID: e7b3c9d5f210
Revises: d4f8a2c6e917
Create Date: 2026-10-20 02:30:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e7b3c9d5f210'
down_revision: Union[str, None] = 'd4f8a2c6e917'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.add_column(sa.Column('photos_changed_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings', schema=None) as batch_op:
        batch_op.drop_column('photos_changed_at')
