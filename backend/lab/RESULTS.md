# Sub-recipe lab: 1→M vs M:N

Should a sub-recipe (the tzatziki inside a gyro) be its own recipe linked by a join
table, or should it stay as more ingredient rows inside the parent, as the app does
today? This lab builds both designs in a separate database and measures them.

- `schema.sql`: both designs. `onem.*` is today's shape; `mn.*` adds
  `recipe_components(user_id, parent_recipe_id, child_recipe_id, position)`.
- `run_lab.py`: checks the constraints, seeds 1k/10k/100k recipes, checks that both
  designs give identical answers on 20 samples per query, then times each query.

```bash
createdb cookbook_lab
cd backend && .venv/bin/python -m lab.run_lab
```

## What the M:N design needs to be safe

All of these are enforced by the database and checked at the start of every run
(`check_constraints`):

| Rule | How |
|---|---|
| No self-link | `CHECK (parent_recipe_id <> child_recipe_id)` |
| No longer cycles (A→B→C→A), including through an UPDATE | `BEFORE INSERT OR UPDATE` trigger: a recursive CTE walks everything below the child and rejects the link if the parent is there |
| No cycle from two concurrent transactions each adding half | The trigger takes a per-user advisory lock first |
| Both ends belong to the same user | Composite FKs `(user_id, parent/child) → recipes(user_id, id)` |
| Deleting a dish | `CASCADE`: its links go |
| Deleting a sauce a dish still uses | `RESTRICT`: refused, so a dish never silently loses part of its recipe |
| Shared sauce (a diamond: gyro→tzatziki, gyro→yogurt, tzatziki→yogurt) | Allowed: it's not a cycle |

1→M needs none of this: a recipe's ingredients belong to it and nothing else.

## Results

Run on 2026-10-24 on an Apple M2 (16 GB RAM), PostgreSQL 14.15 (Homebrew), on the
same machine as the client. Times are client-side medians of 200 runs, including the
round trip. Ten users, so each user owns 100, 1,000 or 10,000 recipes. Every write is
rolled back.

**Seeded data** (synthetic: 3–10 ingredients per recipe, 30% of recipes use 1–2
sub-recipes):

| Recipes | Links | Max nesting | Ingredient rows M:N / 1→M | Size M:N / 1→M |
|---|---|---|---|---|
| 1,000 | 260 | 3 | 6,500 / 8,554 | 1.1 / 1.1 MB |
| 10,000 | 4,395 | 8 | 65,000 / 114,497 | 8.7 / 12.5 MB |
| 100,000 | 45,054 | 15 | 650,000 / 1,184,647 | 83.9 / 127.4 MB |

The nesting depths are far deeper than real recipes (one level, occasionally two), so
these numbers are a worst case for M:N.

**Median milliseconds:**

| Query | Design | 1k | 10k | 100k |
|---|---|---|---|---|
| Load one recipe with all its ingredients | 1→M | 0.14 | 0.15 | 0.14 |
| | M:N, plain join | 0.43 | **2.99** | 0.12 |
| | M:N, LATERAL join | 0.12 | 0.16 | 0.09 |
| Search one user's recipes by ingredient (newest 50) | 1→M | 1.30 | 15.88 | **9.52** |
| | M:N | 1.21 | 10.14 | **69.18** |
| Save a dish (8 ingredients) | 1→M | 0.28 | 0.27 | 0.28 |
| Save a dish (8 ingredients + 2 links, trigger runs) | M:N | 0.48 | 0.44 | 0.46 |
| Link two existing recipes (cycle check passes) | M:N | 0.19 | 0.17 | 0.18 |
| Reject a cycle | M:N | 0.19 | 0.17 | 0.18 |

## What it means

- **Loading a recipe is fast either way, but M:N has a planner trap.** At 10k recipes
  the plain M:N query took 3 ms instead of 0.15 ms. `EXPLAIN` showed why: PostgreSQL
  guessed that the recursive CTE would return 151 rows (it returned 15), so it chose a
  hash join that read the whole ingredients table (547 buffers instead of 11). At 100k
  the statistics changed and it picked the index again. Forcing a per-node index lookup
  with `CROSS JOIN LATERAL (... OFFSET 0)` was fast at every size. The lesson: recursive
  queries need `EXPLAIN ANALYZE` at realistic sizes, not just a passing test.
- **Search gets worse with M:N at scale.** With 1→M, "newest 50 recipes containing
  garlic" walks recipes newest-first and stops after 50 hits. With M:N a dish matches
  when *any recipe below it* has garlic, so PostgreSQL has to find every match and walk
  up through the links before it can sort. At 10,000 recipes per user that's 69 ms
  against 9.5 ms. At 100 or 1,000 per user, M:N was slightly faster, because it has
  fewer ingredient rows to scan.
- **Writes cost about 0.2 ms more**, for the cycle-check trigger. That doesn't matter.
- **Storage:** 1→M stores shared sauces repeatedly (1.8× the ingredient rows here).
  That's only true if sauces really are shared. In a personal cookbook imported from
  posts, each post's tzatziki is its own text, so in practice the duplication would be
  small.

## Recommendation

**Stay with 1→M in the app.** The performance gap is small at a personal cookbook's
size (hundreds of recipes per user, where both designs answer in about 1 ms). But M:N
brings real complexity that no current feature needs:

- a cycle trigger with locking;
- composite FKs;
- a RESTRICT rule the app would need to explain ("this sauce is used in 3 dishes");
- recursive queries with a known planner trap;
- search that can't stop early.

The app also has no screen yet that browses sauces on their own or reuses one across
dishes.

**Revisit when** a feature needs a sub-recipe as a shared, independently edited thing:
for example "use my saved tzatziki in this gyro" with edits showing up in both places,
or scaling a dish together with its sauce. Then start from `schema.sql`'s `mn` design
(the composite FKs, the trigger and the LATERAL load query), and check search with
`EXPLAIN ANALYZE` at the largest real user's size.

## Limits of this lab

- The data is synthetic: ingredient names are `ing_000`–`ing_499` and nesting is
  deeper than real life. Title search wasn't measured: it's identical in both designs.
- Lab ids are `bigint`; the app uses UUIDs, which make indexes somewhat larger.
- Single client, warm cache, one machine. No concurrent-write load test of the advisory
  lock; only the single-session cycle checks were run.
