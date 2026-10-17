"""What the buyer ordered: the listing's title and cover at the moment of the order

Revision ID: b3e8d1f4a925
Revises: a9d4f2c7e310
Create Date: 2026-10-17 21:30:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b3e8d1f4a925'
down_revision: Union[str, None] = 'a9d4f2c7e310'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('listing_title', sa.String(length=120), nullable=True))
        batch.add_column(sa.Column('listing_cover', sa.String(length=500), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.drop_column('listing_cover')
        batch.drop_column('listing_title')
