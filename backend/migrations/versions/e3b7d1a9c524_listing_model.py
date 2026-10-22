"""a listing's 3D model: the light and sharp glTF files and the colour among the model's own

Revision ID: e3b7d1a9c524
Revises: d8f2a6c4e391
Create Date: 2026-10-22 12:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e3b7d1a9c524'
down_revision: Union[str, None] = 'd8f2a6c4e391'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('model_url', sa.String(length=500), nullable=True))
        batch.add_column(sa.Column('model_hq_url', sa.String(length=500), nullable=True))
        batch.add_column(sa.Column('model_variant', sa.String(length=40), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('model_variant')
        batch.drop_column('model_hq_url')
        batch.drop_column('model_url')
