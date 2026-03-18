#!/bin/sh
set -e

# Initialize database (create tables if they don't exist)
echo "Initializing database..."
cd /app
python -c "from app.db import init_db; init_db()" || echo "Warning: init_db failed, continuing"

exec "$@"
