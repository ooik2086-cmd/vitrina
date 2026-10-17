"""stock alerts

Revision ID: e8c2b6d4a937
Revises: d2a6f8c4b715
Create Date: 2026-10-17 14:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e8c2b6d4a937'
down_revision: Union[str, None] = 'd2a6f8c4b715'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'stock_alerts',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('listing_id', sa.Integer(), nullable=False),
        sa.Column('size_id', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['listing_id'], ['listings.id']),
        sa.ForeignKeyConstraint(['size_id'], ['listing_sizes.id']),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'size_id'),
    )
    op.create_index(op.f('ix_stock_alerts_user_id'), 'stock_alerts', ['user_id'], unique=False)
    op.create_index(op.f('ix_stock_alerts_listing_id'), 'stock_alerts', ['listing_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_stock_alerts_listing_id'), table_name='stock_alerts')
    op.drop_index(op.f('ix_stock_alerts_user_id'), table_name='stock_alerts')
    op.drop_table('stock_alerts')
