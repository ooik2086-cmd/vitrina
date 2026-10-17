"""listing questions and answers

Revision ID: e2c8a4f6b937
Revises: d7b3f9a1c526
Create Date: 2026-10-17 20:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e2c8a4f6b937'
down_revision: Union[str, None] = 'd7b3f9a1c526'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'questions',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('listing_id', sa.Integer(), sa.ForeignKey('listings.id'), nullable=False),
        sa.Column('asker_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('text', sa.String(length=500), nullable=False),
        sa.Column('answer', sa.String(length=1000), nullable=True),
        sa.Column('answered_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('hidden', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_questions_listing_id', 'questions', ['listing_id'])
    op.create_index('ix_questions_asker_id', 'questions', ['asker_id'])


def downgrade() -> None:
    op.drop_index('ix_questions_asker_id', table_name='questions')
    op.drop_index('ix_questions_listing_id', table_name='questions')
    op.drop_table('questions')
