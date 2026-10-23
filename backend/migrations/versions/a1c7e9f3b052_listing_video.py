"""The seller's own video of a pair, up to a minute

Revision ID: a1c7e9f3b052
Revises: f6c2a8d4e195
Create Date: 2026-10-22 18:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'a1c7e9f3b052'
down_revision: Union[str, None] = 'f6c2a8d4e195'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # All nullable: a pair has no video until its seller adds one.
    op.add_column('listings', sa.Column('video_state', sa.String(length=12), nullable=True))
    op.add_column('listings', sa.Column('video_url', sa.String(length=500), nullable=True))
    op.add_column('listings', sa.Column('video_poster_url', sa.String(length=500), nullable=True))
    op.add_column('listings', sa.Column('video_seconds', sa.Integer(), nullable=True))
    op.add_column('listings', sa.Column('video_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        for column in ('video_at', 'video_seconds', 'video_poster_url', 'video_url', 'video_state'):
            batch.drop_column(column)
