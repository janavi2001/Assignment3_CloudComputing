"""Application package."""

# Expose app factory for gunicorn
from app.main import create_app

__all__ = ["create_app"]
