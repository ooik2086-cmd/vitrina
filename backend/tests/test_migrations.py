import os
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


if __name__ == "__main__":
    unittest.main()
