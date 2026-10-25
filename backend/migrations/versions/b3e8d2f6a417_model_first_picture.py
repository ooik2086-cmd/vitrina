"""The 3D model's own first picture, shown while the model loads

Revision ID: b3e8d2f6a417
Revises: a1c7e9f3b052
Create Date: 2026-10-25 12:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'b3e8d2f6a417'
down_revision: Union[str, None] = 'a1c7e9f3b052'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Nullable: models given before it, and by address, have none; the page then waits for the model.
    op.add_column('listings', sa.Column('model_first_url', sa.String(length=500), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('model_first_url')
