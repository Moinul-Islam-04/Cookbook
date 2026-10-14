"""Device bearer tokens for single-user self-hosting (auth_mode=token).

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "api_tokens",
        sa.Column("id", UUID, server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("user_id", UUID, nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("created_at", TS, nullable=False, server_default=sa.func.now()),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("last_used_at", TS, nullable=True),
        sa.Column("revoked_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_api_tokens"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_api_tokens_user_id_users", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("token_hash", name="uq_api_tokens_token_hash"),
        sa.CheckConstraint("btrim(name) <> ''", name="name_not_blank"),
    )
    op.create_index("ix_api_tokens_user_id", "api_tokens", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_api_tokens_user_id", table_name="api_tokens")
    op.drop_table("api_tokens")
