"""Small copies of showcase photos for scrolling, and the backdrop that suits the shoe

Revision ID: e6b8d4f0a253
Revises: d5a7c3e9f142
Create Date: 2026-10-18 09:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e6b8d4f0a253'
down_revision: Union[str, None] = 'd5a7c3e9f142'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Existing listings get both from scripts/cutout_backfill.py; until then the app shows the full photos.
    with op.batch_alter_table('media') as batch:
        batch.add_column(sa.Column('thumb_url', sa.String(length=500), nullable=True))
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('backdrop', sa.String(length=10), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('backdrop')
    with op.batch_alter_table('media') as batch:
        batch.drop_column('thumb_url')
