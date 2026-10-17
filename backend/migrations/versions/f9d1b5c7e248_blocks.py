"""users blocking each other

Revision ID: f9d1b5c7e248
Revises: e2c8a4f6b937
Create Date: 2026-10-17 21:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'f9d1b5c7e248'
down_revision: Union[str, None] = 'e2c8a4f6b937'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'blocks',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('blocked_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint('user_id', 'blocked_id'),
    )
    op.create_index('ix_blocks_user_id', 'blocks', ['user_id'])
    op.create_index('ix_blocks_blocked_id', 'blocks', ['blocked_id'])


def downgrade() -> None:
    op.drop_index('ix_blocks_blocked_id', table_name='blocks')
    op.drop_index('ix_blocks_user_id', table_name='blocks')
    op.drop_table('blocks')
