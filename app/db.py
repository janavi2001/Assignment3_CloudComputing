"""Database configuration and session management."""
import os

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.models import Base


def get_database_url() -> str:
    """Build a database URL from environment configuration.

    Priority:
    1) DATABASE_URL
    2) components: DB_USER, DB_PASSWORD, DB_HOST, DB_PORT, DB_NAME
    """

    url = os.environ.get("DATABASE_URL")
    if url:
        return url

    user = os.environ.get("DB_USER", "postgres")
    password = os.environ.get("DB_PASSWORD", "postgres")
    host = os.environ.get("DB_HOST", "postgres")
    port = os.environ.get("DB_PORT", "5432")
    dbname = os.environ.get("DB_NAME", "postgres")

    # Use postgresql+psycopg dialect for psycopg3 (psycopg[binary])
    return f"postgresql+psycopg://{user}:{password}@{host}:{port}/{dbname}"


# Lazy engine initialization: only created on first use
_engine = None
_session_local = None


def get_engine():
    """Get or create the database engine."""
    global _engine
    if _engine is None:
        url = get_database_url()
        _engine = create_engine(url, future=True)
    return _engine


def get_session_factory():
    """Get or create the session factory."""
    global _session_local
    if _session_local is None:
        _session_local = sessionmaker(
            bind=get_engine(), autoflush=False, autocommit=False, future=True
        )
    return _session_local


def get_session():
    """Get a new database session."""
    return get_session_factory()()


def init_db():
    """Initialize database (create tables if they don't exist)."""
    Base.metadata.create_all(bind=get_engine())
