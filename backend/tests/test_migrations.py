import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import create_engine

from vitrina_api.models import Base

ROOT = Path(__file__).resolve().parent.parent


def insert_row(db, table, values):
    """A row with the given values and a placeholder in every other required column."""
    row = {}
    for _, name, typ, notnull, _, pk in db.execute(f"pragma table_info({table})").fetchall():
        if pk:
            continue
        if name in values:
            row[name] = values[name]
        elif notnull:
            row[name] = 0 if any(t in typ.upper() for t in ("INT", "BOOL", "NUM")) else (
                "2026-01-01 00:00:00" if "DATE" in typ.upper() else "x")
    db.execute(f"insert into {table} ({','.join(row)}) values ({','.join('?' * len(row))})", list(row.values()))
    return db.execute("select last_insert_rowid()").fetchone()[0]


class MigrationTests(unittest.TestCase):
    def test_migrations_build_exactly_the_model_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            url = f"sqlite:///{os.path.join(tmp, 'm.db')}"
            cfg = Config(str(ROOT / "alembic.ini"))
            cfg.set_main_option("sqlalchemy.url", url)
            command.upgrade(cfg, "head")
            engine = create_engine(url)
            with engine.connect() as conn:
                diff = compare_metadata(MigrationContext.configure(conn), Base.metadata)
            engine.dispose()
            self.assertEqual(diff, [], "models changed without a migration: run `alembic revision --autogenerate`")
            command.downgrade(cfg, "base")

    def test_old_orders_get_the_listing_text_marked_as_backfilled(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "m.db")
            cfg = Config(str(ROOT / "alembic.ini"))
            cfg.set_main_option("sqlalchemy.url", f"sqlite:///{path}")
            command.upgrade(cfg, "c4f9e2a1b736")
            db = sqlite3.connect(path)

            def insert(table, values):
                return insert_row(db, table, values)

            lid = insert("listings", {"title": "Кроссовки", "brand": "Nike", "condition": "used_good",
                                      "defects": "Сызат", "description": None})
            first, second = insert("orders", {"listing_id": lid}), insert("orders", {"listing_id": lid})
            orphan = insert("orders", {"listing_id": 999})
            db.commit()
            db.close()
            command.upgrade(cfg, "head")
            db = sqlite3.connect(path)
            got = dict(db.execute("select id, listing_details from orders").fetchall())
            db.close()
            details = json.loads(got[first])
            self.assertEqual((details["brand"], details["condition"], details["defects"], details["backfilled"]),
                             ("Nike", "used_good", "Сызат", True))
            self.assertEqual(got[second], got[first])
            self.assertIsNone(got[orphan])
            command.downgrade(cfg, "c4f9e2a1b736")

    def test_colours_typed_before_the_picker_get_their_kazakh_name_and_search_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "m.db")
            cfg = Config(str(ROOT / "alembic.ini"))
            cfg.set_main_option("sqlalchemy.url", f"sqlite:///{path}")
            command.upgrade(cfg, "e6b8d4f0a253")
            db = sqlite3.connect(path)
            black = insert_row(db, "listings", {"title": "Кроссовка", "brand": "Nike", "color": "Черный",
                                                "category": "sneakers", "search_text": "krossovka nike chernyi"})
            marble = insert_row(db, "listings", {"title": "Кроссовка", "color": "мраморный", "search_text": "old"})
            db.commit()
            db.close()
            command.upgrade(cfg, "head")
            db = sqlite3.connect(path)
            got = {i: (c, t) for i, c, t in db.execute("select id, color, search_text from listings")}
            db.close()
            self.assertEqual(got[black], ("қара", "krossovka nike qara sneakers"))
            self.assertEqual(got[marble], ("мраморный", "old"))  # not listed: left as it was


if __name__ == "__main__":
    unittest.main()
