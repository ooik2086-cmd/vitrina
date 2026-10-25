"""Alerts on the phone while the app is closed: the phones' push tokens, and which notifications were pushed

Revision ID: c4f9a1e7d258
Revises: b3e8d2f6a417
Create Date: 2026-10-25 18:00:00

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = 'c4f9a1e7d258'
down_revision: Union[str, None] = 'b3e8d2f6a417'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'push_devices',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('token', sa.String(length=400), nullable=False, unique=True),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('auth_token_id', sa.Integer(), sa.ForeignKey('auth_tokens.id', ondelete='CASCADE'), nullable=False),
        sa.Column('lang', sa.String(length=2), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_push_devices_user_id', 'push_devices', ['user_id'])
    op.create_index('ix_push_devices_auth_token_id', 'push_devices', ['auth_token_id'])
    op.add_column('notifications', sa.Column('pushed_at', sa.DateTime(timezone=True), nullable=True))
    # Everything already there is old news: only notifications made from now on reach the phones.
    op.execute("UPDATE notifications SET pushed_at = created_at")
    op.create_index('ix_notifications_unpushed', 'notifications', ['id'],
                    postgresql_where=sa.text('pushed_at IS NULL'), sqlite_where=sa.text('pushed_at IS NULL'))


def downgrade() -> None:
    op.drop_index('ix_notifications_unpushed', table_name='notifications')
    with op.batch_alter_table('notifications') as batch:
        batch.drop_column('pushed_at')
    op.drop_index('ix_push_devices_auth_token_id', table_name='push_devices')
    op.drop_index('ix_push_devices_user_id', table_name='push_devices')
    op.drop_table('push_devices')
