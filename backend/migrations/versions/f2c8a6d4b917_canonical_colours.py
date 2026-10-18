"""Colours typed before the picker are stored by their Kazakh name

Revision ID: f2c8a6d4b917
Revises: e6b8d4f0a253
Create Date: 2026-10-19 06:00:00

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from vitrina_core.catalog import normalize_query
from vitrina_core.colors import canonical_color


revision: str = 'f2c8a6d4b917'
down_revision: Union[str, None] = 'e6b8d4f0a253'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # "Черный" and "black" become "қара", so a model's colours group and search finds them; the search text is
    # rebuilt as the listing routes build it.
    bind = op.get_bind()
    rows = bind.execute(sa.text("SELECT id, title, brand, model_name, color, category FROM listings")).all()
    for id_, title, brand, model_name, color, category in rows:
        new = canonical_color(color or "")
        if new == color:
            continue
        text = normalize_query(" ".join(filter(None, [title, brand, model_name, new, category])))
        bind.execute(sa.text("UPDATE listings SET color = :color, search_text = :text WHERE id = :id"),
                     {"color": new, "text": text, "id": id_})


def downgrade() -> None:
    pass  # the typed spelling is not kept; the Kazakh name is the same colour
