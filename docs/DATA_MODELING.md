# Data modeling: a method you can reuse

Andrew's goal: name any random thing and get back a reasonable data model. That's a
skill you learn by running the same short method every time. This page has the method,
this app's schema worked through it, four more examples, and practice prompts.

Notation: `table(column, ...)`, with PK = primary key, FK = foreign key and
`→` meaning "belongs to".

## The method (eight questions, in order)

1. **What must it answer?** Write the 3–5 screens or questions first ("show my recipes
   newest first", "search by ingredient", "has this post been saved before?"). The
   model exists to serve them. Anything no question needs can wait.
2. **What are the nouns?** Underline them in those questions. Each noun with its own
   identity and lifetime is a candidate **entity** (a table): recipe, ingredient, user.
   A noun that's just a property of another (a title, a quantity) is a **column**.
3. **How do they relate, and how many?** For each pair, ask the question both ways:
   - **1:1**: one user has one profile. Usually just columns on the same table. Split it
     only when one side is optional, large or sensitive.
   - **1:N**: one recipe has many steps; a step belongs to exactly one recipe. The FK
     goes on the "many" side (`recipe_steps.recipe_id`). This is most relationships.
   - **M:N**: a student takes many classes, a class has many students. This needs a
     **join table** (`enrollments(student_id, class_id)`) with a FK to each side. If
     the link itself has facts (a grade, a position, a date), they go on the join
     table.
4. **Who owns what?** Pick the root each row belongs to, usually a user or an account.
   Every table can reach its owner through FKs. That gives you privacy checks ("only
   my rows") and what to delete with what (`ON DELETE CASCADE`).
5. **Row, column or JSON?** If you query, filter, join or constrain it, it's a column,
   or a child table when there are many. If it's always read and written as one blob
   and never searched inside, JSONB is fine. A list you'd search goes in a child
   table, not an array.
6. **Keys and constraints.** A PK for every table. FKs for every reference. `NOT NULL`
   for everything that must exist. `CHECK` for rules ("quantity > 0"). `UNIQUE` for
   things that can't repeat. The database enforces these even when the code has a
   bug.
7. **Indexes, from the questions.** Each question from step 1 becomes a `WHERE` and an
   `ORDER BY`, and those columns get an index (most-selective or equality column
   first). Index every FK as well, so cascades and joins don't scan.
8. **Normalize, then denormalize only for a measured reason.** Store each fact once.
   Copy a fact (a snapshot, a cached total) only when you must keep history ("the
   price when ordered") or when a measured query is too slow.

Then sanity-check the result: walk through each question as SQL, and try to save one
bad row (a negative quantity, another user's FK). The schema should reject it.

## Worked example: this app

The questions (from `docs/BRIEF.md`): list my recipes newest first; open one with its
ingredients and steps in order; search by title or ingredient; warn if I've saved this
Instagram post before; review an AI draft before saving; attach photos.

**Entities and relationships** (`backend/app/models.py`):

```
users ─1:N─ recipes ─1:N─ recipe_ingredients
  │            ├─1:N─ recipe_steps
  │            └─1:N─ recipe_images
  ├─1:N─ import_drafts ─(N:1, optional)─ recipes   (saved_recipe_id)
  ├─1:N─ api_tokens
  └─1:N─ idempotency_keys ─(N:1, optional)─ recipes
```

How each step of the method shows up:

- **Ownership by FK, child side only.** The docstring states the rule
  (`backend/app/models.py:1-6`): `recipes.user_id → users.id` (`models.py:96-98`), and
  each child points at its recipe (`models.py:223-225`). No table stores a list of
  child IDs. Every query starts with `WHERE user_id = :me`, and deleting a user cascades
  to everything they own. Migration `0001_initial_recipes`.
- **Order is data.** Ingredients and steps have a `position` column with
  `UNIQUE (recipe_id, position)` (`models.py:234`, `models.py:282`). Rows in a table
  have no order, so if order matters you store it. (DECISIONS 2026-10-14, "Positions
  come from array order".)
- **Constraints carry product rules.** `quantity IS NULL OR quantity > 0`
  (`models.py:237`): a missing amount is NULL, never 0 or a guess. `raw_text` is
  `NOT NULL`, because what the caption actually said is always kept
  (`models.py:230`, `models.py:239`). The title isn't blank and is at most 200
  characters (`models.py:137-138`).
- **Indexes come from the questions.** "Newest first for one user" →
  `(user_id, created_at, id)` (`models.py:142`). "Saved this post before?" →
  `(user_id, source_post_key)` (`models.py:144`). It's deliberately *not* unique,
  because the user may save a copy on purpose.
- **JSONB where it's read and written whole.** A draft is edited as one unit and
  thrown away after 24 h, so its content is one JSONB column (`models.py:193`)
  instead of three child tables. Migration `0003_import_drafts`, DECISIONS "Drafts are
  a separate table with whole-draft JSONB content". The model's original output is
  JSONB too (`models.py:111`, migration `0006_extracted_content`): it's only read by
  the corrections report.
- **Composite primary key when the identity is the pair.** An idempotency key is
  unique per user, not globally, so the PK is `(user_id, key)` (`models.py:171`,
  migration `0002_idempotency_keys`).
- **ON DELETE is a product decision.** Children `CASCADE` with their recipe.
  `import_drafts.saved_recipe_id` and `idempotency_keys.recipe_id` use `SET NULL`
  (`models.py:166`, `models.py:202`): deleting a recipe shouldn't delete the record that
  a request or a draft happened.
- **Bytes stay out of the database.** `recipe_images` stores metadata and an S3
  `object_key` (`models.py:243-268`, migration `0005_recipe_images`). The photo itself
  lives in object storage.
- **Secrets are stored hashed.** `api_tokens.token_hash` (`models.py:80`, migration
  `0004_api_tokens`). The plain token is shown once and never stored.

**A design that was considered: sub-recipes.** "Tzatziki inside a gyro" could be its
own recipe linked by a join table `recipe_components(parent_recipe_id,
child_recipe_id)`, an M:N relationship of `recipes` with itself. M:N self-references
bring new problems: cycles (A inside B inside A), deciding what deleting a shared sauce
does, and recursive queries. The app keeps 1:N for now. `backend/lab/` builds both
designs and measures them; see `backend/lab/RESULTS.md`.

## Four more examples

### A gym tracker

Questions: log today's workout; show my history for bench press; what's my best set?

```
users(id PK)
exercises(id PK, name UNIQUE)                        -- shared catalog, not owned by a user
workouts(id PK, user_id FK → users, started_at)      -- index (user_id, started_at)
sets(id PK, workout_id FK → workouts, exercise_id FK → exercises,
     position, reps CHECK > 0, weight_kg CHECK >= 0)  -- index (exercise_id, workout_id)
```

- A set belongs to one workout (1:N) and names one exercise (N:1). Workouts and
  exercises are effectively M:N, and `sets` is the join table with facts on it (reps,
  weight).
- "Best set" is a query (`max(weight_kg)`), not a stored column, until it's measured as
  too slow.
- Weight is in one unit (kg). Convert for display; don't store mixed units.

### A library

Questions: is this book available? Who has it, and when is it due? What has this member
borrowed?

```
books(id PK, isbn UNIQUE, title)                     -- the work
copies(id PK, book_id FK → books, barcode UNIQUE)    -- the physical item
members(id PK, email UNIQUE)
loans(id PK, copy_id FK → copies, member_id FK → members,
      borrowed_at, due_at, returned_at NULL)
  -- partial unique index: UNIQUE (copy_id) WHERE returned_at IS NULL
```

- The key insight is **book vs copy**: "the book" is two nouns. Availability is about
  copies.
- The partial unique index makes the rule "a copy is on at most one open loan" a
  database fact, not just application logic.
- Loans keep history, so returning a book sets `returned_at` instead of deleting the
  row.

### A ride-share

Questions: request a ride; match a driver; show the fare; rate each other.

```
riders(id PK), drivers(id PK, vehicle_plate UNIQUE)
rides(id PK, rider_id FK, driver_id FK NULL, status CHECK IN ('requested','matched',
      'on_trip','done','cancelled'), requested_at, pickup_lat, pickup_lng,
      fare_cents NULL CHECK >= 0)
ratings(ride_id FK → rides, from_role CHECK IN ('rider','driver'), stars CHECK 1..5,
        PRIMARY KEY (ride_id, from_role))
```

- `driver_id` is NULL until matched. A status column with a CHECK models the state
  machine.
- Money is stored as integer cents, never floats.
- The fare is **copied onto the ride** when it's quoted. Prices change later, and the
  receipt must not. This is denormalization for history, the legitimate kind.
- The composite PK on ratings means at most one rating from each side per ride.

### Playlists (M:N with order)

Questions: show a playlist in order; which playlists contain this song?

```
songs(id PK, title), playlists(id PK, owner_id FK, name)
playlist_items(playlist_id FK, song_id FK, position,
               PRIMARY KEY (playlist_id, position))  -- index (song_id) for the reverse lookup
```

- The same song can appear twice in one playlist, so the PK is
  `(playlist_id, position)`, not `(playlist_id, song_id)`. The questions decide the key.
- This is the same shape as recipe ingredients, but with a shared catalog on the other
  side.

## Common mistakes to look for

- A list stored in a column (`ingredient_ids = '1,4,9'`): it can't be joined,
  constrained or indexed. Use a child or join table.
- A FK with no index: every delete of the parent scans the child table.
- A UNIQUE constraint where real life allows repeats (duplicate saves, the same song
  twice), or no UNIQUE where it doesn't (one open loan per copy).
- Floats for money or for exact quantities. Use integer cents or `NUMERIC`.
- Storing what can be computed (totals, counts, "is available") before a query is
  measured as slow.
- Forgetting who owns a row: two users' data must never be one join away from each
  other.

## Practice prompts

For each one, do steps 1–8 on paper, then write the `CREATE TABLE`s and two of the
questions as SQL.

1. A restaurant reservation system (tables, time slots, party size, no-shows).
2. A shared household chores app (rotating assignments, completions, streaks).
3. A plant-watering tracker with photos and species care guides.
4. A course platform: courses, lessons in order, enrollments, progress per lesson.
5. A meal planner built on this app: a week's plan, each slot pointing at a recipe, and
   a generated shopping list. What's stored, and what's computed?
6. Event ticketing with seat maps, where two people must never buy the same seat. Which
   constraint guarantees it?
