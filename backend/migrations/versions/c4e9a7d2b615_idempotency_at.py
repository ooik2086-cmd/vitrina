"""When each idempotent request was first made, so a seller's mistaken "sold" mark can be taken back soon after

Revision ID: c4e9a7d2b615
Revises: b8d2f4a6c931
Create Date: 2026-10-21 12:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'c4e9a7d2b615'
down_revision: Union[str, None] = 'b8d2f4a6c931'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable: rows from before have no time and are treated as long past, so nothing old can be undone.
    op.add_column('idempotency_records', sa.Column('at', sa.DateTime(timezone=True), nullable=True))
    # Then a database default, added after the column so old rows stay empty rather than get this migration's time.
    # New rows get it also from the image before this one, which does not know the column.
    with op.batch_alter_table('idempotency_records') as batch:
        batch.alter_column('at', existing_type=sa.DateTime(timezone=True), server_default=sa.func.now())


def downgrade() -> None:
    with op.batch_alter_table('idempotency_records') as batch:
        batch.drop_column('at')
