"""Idempotency keys for POST /v1/recipes.

Search and duplicate checks need no schema change: recipes.source_post_key and its
(user_id, source_post_key) index already exist from 0001.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)


def upgrade() -> None:
    op.create_table(
        "idempotency_keys",
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("request_hash", sa.Text(), nullable=False),
        sa.Column("response_status", sa.Integer(), nullable=False),
        sa.Column("response_body", postgresql.JSONB(), nullable=False),
        sa.Column("recipe_id", UUID, nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.PrimaryKeyConstraint("user_id", "key", name="pk_idempotency_keys"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_idempotency_keys_user_id_users", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["recipe_id"],
            ["recipes.id"],
            name="fk_idempotency_keys_recipe_id_recipes",
            ondelete="SET NULL",
        ),
        sa.CheckConstraint("char_length(key) BETWEEN 1 AND 255", name="key_length"),
    )
    op.create_index("ix_idempotency_keys_recipe_id", "idempotency_keys", ["recipe_id"])


def downgrade() -> None:
    op.drop_index("ix_idempotency_keys_recipe_id", table_name="idempotency_keys")
    op.drop_table("idempotency_keys")
