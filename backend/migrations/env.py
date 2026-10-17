"""Alembic environment: the schema is vitrina_api.models, the URL is VITRINA_DATABASE_URL."""
from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool

from vitrina_api.config import Settings
from vitrina_api.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def database_url() -> str:
    # Tests and tools may pass a URL explicitly; otherwise use the same setting as the app.
    return config.get_main_option("sqlalchemy.url") or Settings().database_url


def run_migrations_offline() -> None:
    context.configure(url=database_url(), target_metadata=target_metadata, literal_binds=True,
                      dialect_opts={"paramstyle": "named"}, render_as_batch=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = create_engine(database_url(), poolclass=pool.NullPool)
    with engine.connect() as connection:
        # Batch mode lets ALTER TABLE work on SQLite as well as PostgreSQL.
        context.configure(connection=connection, target_metadata=target_metadata, render_as_batch=True,
                          compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
