"""Keep each imported post as the device read it, so imports can be re-parsed later.

raw_posts holds one snapshot per import: caption, optional transcript and comments, the
normalized link and handle. Drafts and recipes point at it with SET NULL foreign keys.
Existing drafts and recipes stay NULL: their caption is in source_text, but the rest of
the post was never sent.

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "raw_posts",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("platform", sa.Text(), nullable=True),
        sa.Column("post_id", sa.Text(), nullable=True),
        sa.Column("url", sa.Text(), nullable=True),
        sa.Column("author_handle", sa.Text(), nullable=True),
        sa.Column("caption", sa.Text(), nullable=False),
        sa.Column("transcript", sa.Text(), nullable=True),
        sa.Column("top_comments", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("media_urls", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False),
        sa.Column("posted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("platform IN ('instagram', 'tiktok')", name="platform_valid"),
        sa.CheckConstraint(
            "(platform IS NULL) = (post_id IS NULL) AND (platform IS NULL) = (url IS NULL)",
            name="identity_complete",
        ),
        sa.CheckConstraint("btrim(caption) <> ''", name="caption_not_blank"),
        sa.CheckConstraint("char_length(caption) <= 10000", name="caption_length"),
        sa.CheckConstraint("char_length(transcript) <= 20000", name="transcript_length"),
        sa.CheckConstraint("jsonb_typeof(top_comments) = 'array'", name="top_comments_array"),
        sa.CheckConstraint("jsonb_typeof(media_urls) = 'array'", name="media_urls_array"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name="fk_raw_posts_user_id_users", ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id", name="pk_raw_posts"),
    )
    op.create_index("ix_raw_posts_user_id_platform_post_id", "raw_posts", ["user_id", "platform", "post_id"])

    for table in ("import_drafts", "recipes"):
        op.add_column(table, sa.Column("raw_post_id", postgresql.UUID(as_uuid=True), nullable=True))
        op.create_foreign_key(
            f"fk_{table}_raw_post_id_raw_posts", table, "raw_posts", ["raw_post_id"], ["id"], ondelete="SET NULL"
        )
        op.create_index(f"ix_{table}_raw_post_id", table, ["raw_post_id"])


def downgrade() -> None:
    for table in ("recipes", "import_drafts"):
        op.drop_index(f"ix_{table}_raw_post_id", table_name=table)
        op.drop_constraint(f"fk_{table}_raw_post_id_raw_posts", table, type_="foreignkey")
        op.drop_column(table, "raw_post_id")
    op.drop_index("ix_raw_posts_user_id_platform_post_id", table_name="raw_posts")
    op.drop_table("raw_posts")
