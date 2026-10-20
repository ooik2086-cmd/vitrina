"""Chat messages indexed by chat and order, and by sender and time

Revision ID: f2a6d8b4c013
Revises: e7b3c9d5f210
Create Date: 2026-10-20 21:20:00

"""
from typing import Sequence, Union

from alembic import op


revision: str = 'f2a6d8b4c013'
down_revision: Union[str, None] = 'e7b3c9d5f210'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # The new index leads with conversation_id, so it replaces the one on that column alone.
    op.create_index('ix_messages_conversation_id_id', 'messages', ['conversation_id', 'id'])
    op.drop_index('ix_messages_conversation_id', 'messages')
    op.create_index('ix_messages_sender_created', 'messages', ['sender_id', 'created_at'])


def downgrade() -> None:
    op.drop_index('ix_messages_sender_created', 'messages')
    op.create_index('ix_messages_conversation_id', 'messages', ['conversation_id'])
    op.drop_index('ix_messages_conversation_id_id', 'messages')
