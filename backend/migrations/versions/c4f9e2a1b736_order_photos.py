"""Every photo the buyer saw when ordering, so the seller may replace listing photos later

Revision ID: c4f9e2a1b736
Revises: b3e8d1f4a925
Create Date: 2026-10-18 03:00:00

"""
import json
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c4f9e2a1b736'
down_revision: Union[str, None] = 'b3e8d1f4a925'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.add_column(sa.Column('listing_photos', sa.Text(), nullable=True))
    # Orders placed before this revision get their copy now. Until now photos could not be removed after sale,
    # so the listing's photos today are the ones each order was placed on (plus any added since).
    bind = op.get_bind()
    media = sa.table('media', sa.column('listing_id'), sa.column('original_url'), sa.column('processed_url'),
                     sa.column('angle'), sa.column('position'))
    orders = sa.table('orders', sa.column('id'), sa.column('listing_id'), sa.column('listing_photos'))
    for listing_id in bind.execute(sa.select(orders.c.listing_id).distinct()).scalars():
        rows = bind.execute(sa.select(media).where(media.c.listing_id == listing_id).order_by(media.c.position))
        copy = json.dumps([{'url': r.processed_url or r.original_url, 'original_url': r.original_url,
                            'angle': r.angle} for r in rows], ensure_ascii=False)
        bind.execute(orders.update().where(orders.c.listing_id == listing_id, orders.c.listing_photos.is_(None))
                     .values(listing_photos=copy))


def downgrade() -> None:
    with op.batch_alter_table('orders') as batch:
        batch.drop_column('listing_photos')
