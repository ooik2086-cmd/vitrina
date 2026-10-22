"""The facts a seller picks for a pair (upper, lining, sole, season, country and a few by kind of footwear)

Revision ID: f6c2a8d4e195
Revises: e3b7d1a9c524
Create Date: 2026-10-22 16:30:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'f6c2a8d4e195'
down_revision: Union[str, None] = 'e3b7d1a9c524'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable: pairs listed before show no facts until their seller picks some.
    op.add_column('listings', sa.Column('facts', sa.JSON(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('facts')
