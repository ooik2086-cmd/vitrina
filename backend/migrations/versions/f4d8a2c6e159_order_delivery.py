"""order delivery address

Revision ID: f4d8a2c6e159
Revises: e8c2b6d4a937
Create Date: 2026-10-17 15:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'f4d8a2c6e159'
down_revision: Union[str, None] = 'e8c2b6d4a937'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('recipient_name', sa.String(length=80), nullable=True))
        batch.add_column(sa.Column('recipient_phone', sa.String(length=16), nullable=True))
        batch.add_column(sa.Column('delivery_city', sa.String(length=60), nullable=True))
        batch.add_column(sa.Column('delivery_address', sa.String(length=200), nullable=True))
        batch.add_column(sa.Column('delivery_note', sa.String(length=200), nullable=True))
    with op.batch_alter_table('users') as batch:
        batch.add_column(sa.Column('last_delivery', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('users') as batch:
        batch.drop_column('last_delivery')
    with op.batch_alter_table('orders') as batch:
        for name in ('delivery_note', 'delivery_address', 'delivery_city', 'recipient_phone', 'recipient_name'):
            batch.drop_column(name)
