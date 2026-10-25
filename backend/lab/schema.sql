-- Sub-recipe lab: two designs side by side, in the separate `cookbook_lab` database.
-- Never applied to the app's databases; run_lab.py drops and recreates both schemas.
--
-- onem: today's app shape. A recipe owns its ingredients (1→M). A sub-recipe (the
--       tzatziki inside a gyro) is just more ingredient rows inside the parent, so the
--       same sauce saved under two dishes is stored twice.
-- mn:   sub-recipes are recipes in their own right, linked by recipe_components
--       (M:N: a sauce can sit inside many dishes, and a dish can have many sauces).
--
-- Simplifications against backend/app/models.py: bigint ids instead of UUIDs (so the
-- seed can guarantee child id < parent id), and no steps, images or timestamps.

DROP SCHEMA IF EXISTS onem CASCADE;
DROP SCHEMA IF EXISTS mn CASCADE;
CREATE SCHEMA onem;
CREATE SCHEMA mn;

-- ---------------------------------------------------------------- onem (1→M) ----

CREATE TABLE onem.users (id bigint PRIMARY KEY);

CREATE TABLE onem.recipes (
    id      bigint PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES onem.users (id) ON DELETE CASCADE,
    title   text   NOT NULL CHECK (btrim(title) <> '')
);
CREATE INDEX ix_onem_recipes_user_id ON onem.recipes (user_id);

CREATE TABLE onem.ingredients (
    recipe_id bigint  NOT NULL REFERENCES onem.recipes (id) ON DELETE CASCADE,
    position  integer NOT NULL CHECK (position >= 0),
    name      text    NOT NULL CHECK (btrim(name) <> ''),
    quantity  numeric(10, 3) CHECK (quantity IS NULL OR quantity > 0),
    unit      text,
    raw_text  text    NOT NULL,
    PRIMARY KEY (recipe_id, position)  -- also serves "this recipe's ingredients"
);

-- ----------------------------------------------------------------- mn (M:N) ----

CREATE TABLE mn.users (id bigint PRIMARY KEY);

CREATE TABLE mn.recipes (
    id      bigint PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES mn.users (id) ON DELETE CASCADE,
    title   text   NOT NULL CHECK (btrim(title) <> ''),
    -- Lets recipe_components reference (user_id, id), so a link can't join two users'
    -- recipes. Its leading user_id also serves plain owner lookups.
    UNIQUE (user_id, id)
);

CREATE TABLE mn.ingredients (
    recipe_id bigint  NOT NULL REFERENCES mn.recipes (id) ON DELETE CASCADE,
    position  integer NOT NULL CHECK (position >= 0),
    name      text    NOT NULL CHECK (btrim(name) <> ''),
    quantity  numeric(10, 3) CHECK (quantity IS NULL OR quantity > 0),
    unit      text,
    raw_text  text    NOT NULL,
    PRIMARY KEY (recipe_id, position)
);

CREATE TABLE mn.recipe_components (
    user_id          bigint  NOT NULL,
    parent_recipe_id bigint  NOT NULL,
    child_recipe_id  bigint  NOT NULL,
    position         integer NOT NULL CHECK (position >= 0),
    PRIMARY KEY (parent_recipe_id, child_recipe_id),  -- one link per pair; walks downward
    UNIQUE (parent_recipe_id, position),
    CHECK (parent_recipe_id <> child_recipe_id),      -- the shortest cycle
    -- Composite keys: both ends must belong to the same user.
    -- Deleting a dish drops its links; deleting a sauce that a dish still uses is refused
    -- (RESTRICT), so a dish never silently loses part of its recipe.
    FOREIGN KEY (user_id, parent_recipe_id) REFERENCES mn.recipes (user_id, id) ON DELETE CASCADE,
    FOREIGN KEY (user_id, child_recipe_id)  REFERENCES mn.recipes (user_id, id) ON DELETE RESTRICT
);
-- Walking upward ("which dishes use this sauce?"), and the RESTRICT check on delete.
CREATE INDEX ix_mn_recipe_components_child ON mn.recipe_components (child_recipe_id);

-- Longer cycles (A→B→C→A) can't be expressed as a CHECK: a new link parent→child makes
-- a cycle exactly when parent is already reachable from child. The per-user advisory
-- lock serializes link writes for one user, so two concurrent transactions can't each
-- add half of a cycle (A→B and B→A) without seeing the other's link.
CREATE FUNCTION mn.reject_component_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('recipe_components'), NEW.user_id::int);
    IF EXISTS (
        WITH RECURSIVE below (id) AS (
            SELECT NEW.child_recipe_id
            UNION
            SELECT c.child_recipe_id
            FROM mn.recipe_components c
            JOIN below b ON c.parent_recipe_id = b.id
        )
        SELECT 1 FROM below WHERE id = NEW.parent_recipe_id
    ) THEN
        RAISE EXCEPTION 'recipe % is already inside recipe %; linking it would make a cycle',
            NEW.parent_recipe_id, NEW.child_recipe_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER recipe_components_no_cycle
    BEFORE INSERT OR UPDATE OF parent_recipe_id, child_recipe_id ON mn.recipe_components
    FOR EACH ROW EXECUTE FUNCTION mn.reject_component_cycle();
