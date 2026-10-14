"""Recipe photos: metadata rows; bytes live in object storage.

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

UUID = postgresql.UUID(as_uuid=True)


def upgrade() -> None:
    op.create_table(
        "recipe_images",
        sa.Column("id", UUID, server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("recipe_id", UUID, nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("object_key", sa.Text(), nullable=False),
        sa.Column("thumb_object_key", sa.Text(), nullable=False),
        sa.Column("content_type", sa.Text(), nullable=False),
        sa.Column("byte_size", sa.Integer(), nullable=False),
        sa.Column("width", sa.Integer(), nullable=False),
        sa.Column("height", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id", name="pk_recipe_images"),
        sa.ForeignKeyConstraint(
            ["recipe_id"], ["recipes.id"], name="fk_recipe_images_recipe_id_recipes", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("recipe_id", "position", name="uq_recipe_images_recipe_id_position"),
        sa.UniqueConstraint("object_key", name="uq_recipe_images_object_key"),
        sa.UniqueConstraint("thumb_object_key", name="uq_recipe_images_thumb_object_key"),
        sa.CheckConstraint("position >= 0", name="position_nonnegative"),
        sa.CheckConstraint("byte_size > 0", name="byte_size_positive"),
        sa.CheckConstraint("width > 0 AND height > 0", name="dimensions_positive"),
    )


def downgrade() -> None:
    op.drop_table("recipe_images")
