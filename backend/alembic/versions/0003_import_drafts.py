"""Import drafts: extracted caption recipes awaiting review.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "import_drafts",
        sa.Column("id", UUID, server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("status", sa.Text(), nullable=False, server_default="ready"),
        sa.Column("source_text", sa.Text(), nullable=False),
        sa.Column("source_url", sa.Text(), nullable=True),
        sa.Column("source_post_key", sa.Text(), nullable=True),
        sa.Column("content", postgresql.JSONB(), nullable=False),
        sa.Column("extraction_version", sa.Text(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("saved_recipe_id", UUID, nullable=True),
        sa.Column("created_at", TS, nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", TS, nullable=False, server_default=sa.func.now()),
        sa.Column("expires_at", TS, nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_import_drafts"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_import_drafts_user_id_users", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["saved_recipe_id"],
            ["recipes.id"],
            name="fk_import_drafts_saved_recipe_id_recipes",
            ondelete="SET NULL",
        ),
        sa.CheckConstraint("status IN ('ready', 'saved')", name="status_valid"),
        sa.CheckConstraint("btrim(source_text) <> ''", name="source_text_not_blank"),
        sa.CheckConstraint("char_length(source_text) <= 10000", name="source_text_length"),
        sa.CheckConstraint("version >= 1", name="version_positive"),
    )
    op.create_index("ix_import_drafts_user_id", "import_drafts", ["user_id"])
    op.create_index("ix_import_drafts_saved_recipe_id", "import_drafts", ["saved_recipe_id"])
    op.create_index("ix_import_drafts_expires_at", "import_drafts", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_import_drafts_expires_at", table_name="import_drafts")
    op.drop_index("ix_import_drafts_saved_recipe_id", table_name="import_drafts")
    op.drop_index("ix_import_drafts_user_id", table_name="import_drafts")
    op.drop_table("import_drafts")
