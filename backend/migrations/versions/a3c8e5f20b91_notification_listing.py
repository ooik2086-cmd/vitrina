"""notification link to a listing

Revision ID: a3c8e5f20b91
Revises: f7b3d1e6a284
Create Date: 2026-10-17 03:50:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a3c8e5f20b91'
down_revision: Union[str, None] = 'f7b3d1e6a284'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.add_column(sa.Column('listing_id', sa.Integer(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('notifications', schema=None) as batch_op:
        batch_op.drop_column('listing_id')
