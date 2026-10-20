"""Whom a pair is made for (men, women, unisex, kids), on listings and saved searches

Revision ID: b8d2f4a6c931
Revises: a3c7e1f5b820
Create Date: 2026-10-21 03:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'b8d2f4a6c931'
down_revision: Union[str, None] = 'a3c7e1f5b820'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable: pairs listed before it was asked stay unsaid until their seller fills it in.
    op.add_column('listings', sa.Column('audience', sa.String(length=10), nullable=True))
    op.add_column('saved_searches', sa.Column('audience', sa.String(length=10), nullable=True))
    # Pairs in the children's category are children's: said once here, so sellers need not.
    op.execute("UPDATE listings SET audience = 'kids' WHERE category = 'kids'")


def downgrade() -> None:
    with op.batch_alter_table('saved_searches') as batch:
        batch.drop_column('audience')
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('audience')
