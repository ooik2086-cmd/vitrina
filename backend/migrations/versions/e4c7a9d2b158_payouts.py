"""Seller payouts to a bank account

Revision ID: e4c7a9d2b158
Revises: d6b1f3a8c427
Create Date: 2026-10-20 12:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e4c7a9d2b158'
down_revision: Union[str, None] = 'd6b1f3a8c427'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'payout_accounts',
        sa.Column('seller_id', sa.Integer(), sa.ForeignKey('users.id'), primary_key=True),
        sa.Column('holder_name', sa.String(120), nullable=False),
        sa.Column('iban', sa.String(20), nullable=False),
        sa.Column('tax_id', sa.String(12), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        'payouts',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('seller_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('amount_tiyn', sa.BigInteger(), nullable=False),
        sa.Column('status', sa.String(10), nullable=False),
        sa.Column('holder_name', sa.String(120), nullable=False),
        sa.Column('iban', sa.String(20), nullable=False),
        sa.Column('tax_id', sa.String(12), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('decided_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('decided_by', sa.Integer(), nullable=True),
        sa.Column('bank_ref', sa.String(60), nullable=True),
        sa.Column('reason', sa.Text(), nullable=True),
    )
    op.create_index('ix_payouts_seller_id', 'payouts', ['seller_id'])
    op.create_index('ix_payouts_status', 'payouts', ['status'])


def downgrade() -> None:
    op.drop_index('ix_payouts_status', table_name='payouts')
    op.drop_index('ix_payouts_seller_id', table_name='payouts')
    op.drop_table('payouts')
    op.drop_table('payout_accounts')
