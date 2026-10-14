"""SQLAlchemy models.

Ownership is expressed only with scalar foreign keys on the child side:
recipes.user_id -> users.id, recipe_ingredients.recipe_id -> recipes.id, and so on.
No table stores a list of child IDs.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Numeric,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


def utcnow() -> datetime:
    return datetime.now(UTC)


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


def uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )


def timestamp() -> Mapped[datetime]:
    return mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow, server_default=func.now()
    )


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = uuid_pk()
    # Populated once real authentication exists; NULL for the local dev user.
    auth_subject: Mapped[str | None] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = timestamp()


class Recipe(Base):
    __tablename__ = "recipes"

    id: Mapped[uuid.UUID] = uuid_pk()
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str] = mapped_column(Text, nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    source_kind: Mapped[str] = mapped_column(
        Text, nullable=False, default="manual", server_default="manual"
    )
    source_url: Mapped[str | None] = mapped_column(Text)
    source_post_key: Mapped[str | None] = mapped_column(Text)
    source_text: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = timestamp()
    updated_at: Mapped[datetime] = timestamp()
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1, server_default="1")

    ingredients: Mapped[list["RecipeIngredient"]] = relationship(
        order_by="RecipeIngredient.position",
        cascade="all, delete-orphan",
        passive_deletes=True,
        lazy="selectin",
    )
    steps: Mapped[list["RecipeStep"]] = relationship(
        order_by="RecipeStep.position",
        cascade="all, delete-orphan",
        passive_deletes=True,
        lazy="selectin",
    )

    __table_args__ = (
        CheckConstraint("btrim(title) <> ''", name="title_not_blank"),
        CheckConstraint("char_length(title) <= 200", name="title_length"),
        CheckConstraint("source_kind IN ('manual', 'caption')", name="source_kind_valid"),
        CheckConstraint("version >= 1", name="version_positive"),
        # Leading user_id column also serves plain owner lookups.
        Index("ix_recipes_user_id_created_at_id", "user_id", "created_at", "id"),
        # Duplicate-post checks (Milestone 2). Not unique: deliberate copies are allowed.
        Index("ix_recipes_user_id_source_post_key", "user_id", "source_post_key"),
    )


class RecipeIngredient(Base):
    __tablename__ = "recipe_ingredients"

    id: Mapped[uuid.UUID] = uuid_pk()
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    quantity: Mapped[Decimal | None] = mapped_column(Numeric(10, 3))
    unit: Mapped[str | None] = mapped_column(Text)
    raw_text: Mapped[str] = mapped_column(Text, nullable=False)

    __table_args__ = (
        # The unique index's leading recipe_id column also serves FK lookups and cascades.
        UniqueConstraint("recipe_id", "position"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        CheckConstraint("btrim(name) <> ''", name="name_not_blank"),
        CheckConstraint("quantity IS NULL OR quantity > 0", name="quantity_positive"),
        CheckConstraint("unit IS NULL OR btrim(unit) <> ''", name="unit_not_blank"),
        CheckConstraint("btrim(raw_text) <> ''", name="raw_text_not_blank"),
    )


class RecipeStep(Base):
    __tablename__ = "recipe_steps"

    id: Mapped[uuid.UUID] = uuid_pk()
    recipe_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    instruction: Mapped[str] = mapped_column(Text, nullable=False)

    __table_args__ = (
        UniqueConstraint("recipe_id", "position"),
        CheckConstraint("position >= 0", name="position_nonnegative"),
        CheckConstraint("btrim(instruction) <> ''", name="instruction_not_blank"),
    )
