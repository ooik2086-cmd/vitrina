"""seller promo codes

Revision ID: d7b3f9a1c526
Revises: c6a2e8f4d483
Create Date: 2026-10-17 19:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd7b3f9a1c526'
down_revision: Union[str, None] = 'c6a2e8f4d483'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'promo_codes',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('seller_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('code', sa.String(length=20), nullable=False),
        sa.Column('percent', sa.Integer(), nullable=True),
        sa.Column('amount_tiyn', sa.BigInteger(), nullable=True),
        sa.Column('min_price_tiyn', sa.BigInteger(), nullable=False),
        sa.Column('max_uses', sa.Integer(), nullable=True),
        sa.Column('ends_on', sa.Date(), nullable=True),
        sa.Column('active', sa.Boolean(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_promo_codes_seller_id', 'promo_codes', ['seller_id'])
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('promo_code_id', sa.Integer(), sa.ForeignKey('promo_codes.id',
                                   name='fk_orders_promo_code_id'), nullable=True))
        batch.add_column(sa.Column('promo_code', sa.String(length=20), nullable=True))
        batch.add_column(sa.Column('promo_discount_tiyn', sa.BigInteger(), nullable=False, server_default='0'))
        batch.create_index('ix_orders_promo_code_id', ['promo_code_id'])


def downgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.drop_index('ix_orders_promo_code_id')
        batch.drop_constraint('fk_orders_promo_code_id', type_='foreignkey')
        batch.drop_column('promo_discount_tiyn')
        batch.drop_column('promo_code')
        batch.drop_column('promo_code_id')
    op.drop_index('ix_promo_codes_seller_id', table_name='promo_codes')
    op.drop_table('promo_codes')
