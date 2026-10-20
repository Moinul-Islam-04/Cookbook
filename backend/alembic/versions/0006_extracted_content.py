"""Keep the model's validated output, so user corrections can be measured.

import_drafts.extracted_content is written once at draft creation and never patched.
Saving a draft copies it and extraction_version onto the recipe, where they outlive draft
cleanup. Existing rows stay NULL: an old draft's `content` may already hold the user's
edits, so it can't stand in for the model's output.

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-20
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("import_drafts", sa.Column("extracted_content", postgresql.JSONB(), nullable=True))
    op.add_column("recipes", sa.Column("extracted_content", postgresql.JSONB(), nullable=True))
    op.add_column("recipes", sa.Column("extraction_version", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("recipes", "extraction_version")
    op.drop_column("recipes", "extracted_content")
    op.drop_column("import_drafts", "extracted_content")
