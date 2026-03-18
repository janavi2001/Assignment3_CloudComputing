"""create items table

Revision ID: 0001_create_items_table
Revises: 
Create Date: 2026-03-17 00:00:00.000000
"""

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = "0001_create_items_table"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "items",
        sa.Column("id", sa.Integer, primary_key=True, nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False, unique=True),
        sa.Column("value", sa.Integer, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index(op.f("ix_items_name"), "items", ["name"], unique=True)


def downgrade() -> None:
    op.drop_index(op.f("ix_items_name"), table_name="items")
    op.drop_table("items")
