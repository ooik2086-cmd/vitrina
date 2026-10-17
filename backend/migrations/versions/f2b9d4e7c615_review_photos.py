"""review photos

Revision ID: f2b9d4e7c615
Revises: e5a1c7d3b824
Create Date: 2026-10-17 09:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'f2b9d4e7c615'
down_revision: Union[str, None] = 'e5a1c7d3b824'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('reviews') as batch:
        batch.add_column(sa.Column('photos', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('reviews') as batch:
        batch.drop_column('photos')
