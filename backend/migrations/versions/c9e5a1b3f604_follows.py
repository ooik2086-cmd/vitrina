"""follows

Revision ID: c9e5a1b3f604
Revises: b8d4f0a2e593
Create Date: 2026-10-17 12:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c9e5a1b3f604'
down_revision: Union[str, None] = 'b8d4f0a2e593'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'follows',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('seller_id', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['seller_id'], ['users.id']),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'seller_id'),
    )
    op.create_index(op.f('ix_follows_user_id'), 'follows', ['user_id'], unique=False)
    op.create_index(op.f('ix_follows_seller_id'), 'follows', ['seller_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_follows_seller_id'), table_name='follows')
    op.drop_index(op.f('ix_follows_user_id'), table_name='follows')
    op.drop_table('follows')
