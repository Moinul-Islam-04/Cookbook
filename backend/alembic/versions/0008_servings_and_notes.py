"""Servings on recipes and a note per ingredient, from the ParsedRecipe mapping.

Both are nullable: existing recipes have neither, and a post often states neither.

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("recipes", sa.Column("servings", sa.Integer(), nullable=True))
    op.create_check_constraint("servings_range", "recipes", "servings BETWEEN 1 AND 1000")
    op.add_column("recipe_ingredients", sa.Column("note", sa.Text(), nullable=True))
    op.create_check_constraint("note_not_blank", "recipe_ingredients", "note IS NULL OR btrim(note) <> ''")


def downgrade() -> None:
    op.drop_column("recipe_ingredients", "note")
    op.drop_column("recipes", "servings")
