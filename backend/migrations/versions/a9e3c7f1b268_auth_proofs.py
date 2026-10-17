"""authenticity proofs

Revision ID: a9e3c7f1b268
Revises: f4d8a2c6e159
Create Date: 2026-10-17 16:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'a9e3c7f1b268'
down_revision: Union[str, None] = 'f4d8a2c6e159'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'auth_proofs',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('listing_id', sa.Integer(), nullable=False),
        sa.Column('url', sa.String(length=500), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['listing_id'], ['listings.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_auth_proofs_listing_id'), 'auth_proofs', ['listing_id'], unique=False)
    with op.batch_alter_table('listings') as batch:
        batch.add_column(sa.Column('authenticity_note', sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('listings') as batch:
        batch.drop_column('authenticity_note')
    op.drop_index(op.f('ix_auth_proofs_listing_id'), table_name='auth_proofs')
    op.drop_table('auth_proofs')
