"""saved searches

Revision ID: e5a1c7d3b824
Revises: d4f8b2c6a913
Create Date: 2026-10-17 08:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e5a1c7d3b824'
down_revision: Union[str, None] = 'd4f8b2c6a913'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'saved_searches',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('q', sa.String(length=100), nullable=True),
        sa.Column('category', sa.String(length=30), nullable=True),
        sa.Column('brand', sa.String(length=60), nullable=True),
        sa.Column('condition', sa.String(length=200), nullable=True),
        sa.Column('min_price_tiyn', sa.BigInteger(), nullable=True),
        sa.Column('max_price_tiyn', sa.BigInteger(), nullable=True),
        sa.Column('size_cm', sa.String(length=8), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_saved_searches_user_id', 'saved_searches', ['user_id'])
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('announced_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('announced_at')
    op.drop_index('ix_saved_searches_user_id', 'saved_searches')
    op.drop_table('saved_searches')
