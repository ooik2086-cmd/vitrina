"""listing moderation

Revision ID: c1e7a4b9d250
Revises: b6d2f9a47c18
Create Date: 2026-10-17 06:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c1e7a4b9d250'
down_revision: Union[str, None] = 'b6d2f9a47c18'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('moderation_flags', sa.String(length=200), nullable=True))
        batch.add_column(sa.Column('moderation_cleared', sa.String(length=200), nullable=True))
        batch.add_column(sa.Column('moderation_note', sa.Text(), nullable=True))
    with op.batch_alter_table('media') as batch:
        batch.add_column(sa.Column('phash', sa.String(length=16), nullable=True))
        batch.create_index('ix_media_phash', ['phash'])


def downgrade() -> None:
    with op.batch_alter_table('media') as batch:
        batch.drop_index('ix_media_phash')
        batch.drop_column('phash')
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('moderation_note')
        batch.drop_column('moderation_cleared')
        batch.drop_column('moderation_flags')
