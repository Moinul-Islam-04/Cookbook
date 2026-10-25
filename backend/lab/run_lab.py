"""Sub-recipe lab: today's 1→M design against an M:N recipe_components design.

    createdb cookbook_lab                                   # once
    .venv/bin/python -m lab.run_lab                         # from backend/: 1k, 10k, 100k recipes
    .venv/bin/python -m lab.run_lab --sizes 1000 --repeat 50

Uses only the `cookbook_lab` database (override with LAB_DATABASE_URL; the name must stay
cookbook_lab). Each size drops and recreates both schemas from schema.sql, so nothing
here touches the app's data. Not a pytest module on purpose: `pytest -q` in backend/
would collect it and need this database.

Both schemas hold the same dishes. The M:N data is generated first; the 1→M data is that
data flattened, so each 1→M recipe holds its own ingredients followed by copies of its
sub-recipes' ingredients, in component order.
"""

import argparse
import os
import random
import statistics
import time
from pathlib import Path

import psycopg

DB_URL = os.environ.get("LAB_DATABASE_URL", "postgresql://localhost:5432/cookbook_lab")
SCHEMA_SQL = (Path(__file__).parent / "schema.sql").read_text()
USERS = 10  # so each user owns size/10 recipes: 100, 1,000 and 10,000
VOCAB = 500  # distinct ingredient names, ing_000 .. ing_499

SEED_MN = """
INSERT INTO mn.users SELECT g FROM generate_series(1, %(users)s) g;
INSERT INTO mn.recipes (id, user_id, title)
    SELECT g, g %% %(users)s + 1, 'recipe ' || g FROM generate_series(1, %(n)s) g;
-- 3 to 10 ingredients each.
INSERT INTO mn.ingredients (recipe_id, position, name, quantity, unit, raw_text)
    SELECT r, p, name, p + 1, 'g', (p + 1) || ' g ' || name
    FROM generate_series(1, %(n)s) r,
         generate_series(0, 2 + r %% 8) p,
         LATERAL (SELECT 'ing_' || lpad(((r * 7 + p * 13) %% %(vocab)s)::text, 3, '0') AS name) x;
-- 30%% of recipes use one or two sub-recipes, picked by a hash so a child is no more
-- likely than any recipe to have children of its own (about 0.45 children per recipe,
-- so nesting stays shallow). A child is a lower id with the same owner
-- (parent - users * k), so the seed is acyclic by construction.
INSERT INTO mn.recipe_components (user_id, parent_recipe_id, child_recipe_id, position)
    SELECT g %% %(users)s + 1, g, g - %(users)s * k, pos
    FROM generate_series(1, %(n)s) g,
         LATERAL (VALUES (0, 1 + (g * 31) %% 50), (1, 51 + (g * 17) %% 50)) v(pos, k)
    WHERE abs(hashint4(g)) %% 10 < 3 AND (pos = 0 OR abs(hashint4(-g)) %% 2 = 0)
      AND g - %(users)s * k >= 1;
"""

FLATTEN_TO_ONEM = """
INSERT INTO onem.users SELECT id FROM mn.users;
INSERT INTO onem.recipes SELECT id, user_id, title FROM mn.recipes;
INSERT INTO onem.ingredients (recipe_id, position, name, quantity, unit, raw_text)
    WITH RECURSIVE tree (root, node, path) AS (
        SELECT id, id, ARRAY[]::int[] FROM mn.recipes
        UNION ALL
        SELECT t.root, c.child_recipe_id, t.path || c.position
        FROM tree t JOIN mn.recipe_components c ON c.parent_recipe_id = t.node
    )
    SELECT t.root, row_number() OVER (PARTITION BY t.root ORDER BY t.path, i.position) - 1,
           i.name, i.quantity, i.unit, i.raw_text
    FROM tree t JOIN mn.ingredients i ON i.recipe_id = t.node;
"""

QUERIES = {
    "load": {
        "onem": "SELECT position, name, quantity, unit, raw_text FROM onem.ingredients "
                "WHERE recipe_id = %(rid)s ORDER BY position",
        "mn": """
            WITH RECURSIVE tree (node, path) AS (
                SELECT %(rid)s::bigint, ARRAY[]::int[]
                UNION ALL
                SELECT c.child_recipe_id, t.path || c.position
                FROM tree t JOIN mn.recipe_components c ON c.parent_recipe_id = t.node
            )
            SELECT t.node, i.position, i.name, i.quantity, i.unit, i.raw_text
            FROM tree t JOIN mn.ingredients i ON i.recipe_id = t.node
            ORDER BY t.path, i.position""",
        # Same query, but LATERAL makes PostgreSQL look up each node's ingredients by
        # index. The plain join above gets a bad row estimate for the recursive CTE and
        # picks a hash join over the whole ingredients table (see RESULTS.md).
        "mn_lateral": """
            WITH RECURSIVE tree (node, path) AS (
                SELECT %(rid)s::bigint, ARRAY[]::int[]
                UNION ALL
                SELECT c.child_recipe_id, t.path || c.position
                FROM tree t JOIN mn.recipe_components c ON c.parent_recipe_id = t.node
            )
            SELECT t.node, i.position, i.name, i.quantity, i.unit, i.raw_text
            FROM tree t CROSS JOIN LATERAL (
                SELECT * FROM mn.ingredients i WHERE i.recipe_id = t.node OFFSET 0) i
            ORDER BY t.path, i.position""",
    },
    # Like the app's search: ILIKE, scoped to one user, newest 50. Under M:N a dish
    # matches when it or any sub-recipe below it has the ingredient.
    "search": {
        "onem": """
            SELECT r.id, r.title FROM onem.recipes r
            WHERE r.user_id = %(uid)s AND EXISTS (
                SELECT 1 FROM onem.ingredients i WHERE i.recipe_id = r.id AND i.name ILIKE %(pat)s)
            ORDER BY r.id DESC LIMIT 50""",
        "mn": """
            WITH RECURSIVE hits (id) AS (
                SELECT i.recipe_id FROM mn.ingredients i JOIN mn.recipes r ON r.id = i.recipe_id
                WHERE r.user_id = %(uid)s AND i.name ILIKE %(pat)s
                UNION
                SELECT c.parent_recipe_id FROM mn.recipe_components c JOIN hits h ON c.child_recipe_id = h.id
            )
            SELECT r.id, r.title FROM mn.recipes r JOIN hits h ON h.id = r.id
            ORDER BY r.id DESC LIMIT 50""",
    },
}


def connect() -> psycopg.Connection:
    if psycopg.conninfo.conninfo_to_dict(DB_URL).get("dbname") != "cookbook_lab":
        raise SystemExit("Refusing to run: LAB_DATABASE_URL must point at the cookbook_lab database.")
    return psycopg.connect(DB_URL, autocommit=True)


def reset(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("SET client_min_messages = warning")
        cur.execute(SCHEMA_SQL)


def check_constraints(conn: psycopg.Connection) -> None:
    """Assertions on an empty schema: the cycle rules and the same-owner rule hold."""
    reset(conn)

    def rejected(sql: str, sqlstate: str) -> bool:
        try:
            with conn.transaction():
                conn.execute(sql)
        except psycopg.Error as e:
            return e.sqlstate == sqlstate
        return False

    conn.execute("INSERT INTO mn.users VALUES (1), (2)")
    conn.execute("INSERT INTO mn.recipes VALUES (1, 1, 'gyro'), (2, 1, 'tzatziki'), (3, 1, 'yogurt'), (4, 2, 'other user')")
    conn.execute("INSERT INTO mn.recipe_components VALUES (1, 1, 2, 0), (1, 2, 3, 0)")  # gyro → tzatziki → yogurt
    assert rejected("INSERT INTO mn.recipe_components VALUES (1, 3, 1, 0)", "23514"), "3-cycle allowed"
    assert rejected("INSERT INTO mn.recipe_components VALUES (1, 2, 1, 1)", "23514"), "2-cycle allowed"
    assert rejected("INSERT INTO mn.recipe_components VALUES (1, 2, 2, 1)", "23514"), "self-link allowed"
    assert rejected("UPDATE mn.recipe_components SET child_recipe_id = 1 WHERE parent_recipe_id = 2", "23514"), \
        "cycle via UPDATE allowed"
    assert rejected("INSERT INTO mn.recipe_components VALUES (1, 1, 4, 1)", "23503"), "cross-user link allowed"
    assert rejected("DELETE FROM mn.recipes WHERE id = 3", "23503"), "deleted a sub-recipe still in use"
    conn.execute("INSERT INTO mn.recipe_components VALUES (1, 1, 3, 1)")  # a diamond is fine: not a cycle
    conn.execute("DELETE FROM mn.recipes WHERE id = 1")  # deleting the dish drops its links
    assert conn.execute("SELECT count(*) FROM mn.recipe_components").fetchone()[0] == 1
    print("constraint checks: 3-cycle, 2-cycle, self-link, cycle by UPDATE, cross-user link and "
          "deleting an in-use sub-recipe are rejected; diamonds and dish deletes work")


def seed(conn: psycopg.Connection, n: int) -> dict:
    reset(conn)
    start = time.perf_counter()
    conn.execute("ALTER TABLE mn.recipe_components DISABLE TRIGGER USER")  # bulk seed is acyclic by construction
    # Client-side binding: the seed is several statements in one call.
    with psycopg.ClientCursor(conn) as cur:
        cur.execute(SEED_MN, {"n": n, "users": USERS, "vocab": VOCAB})
    conn.execute("ALTER TABLE mn.recipe_components ENABLE TRIGGER USER")
    assert conn.execute(
        "SELECT count(*) FROM mn.recipe_components WHERE child_recipe_id >= parent_recipe_id").fetchone()[0] == 0
    conn.execute("ANALYZE mn.recipes, mn.ingredients, mn.recipe_components")  # else the flatten plans a nested loop
    conn.execute(FLATTEN_TO_ONEM)
    conn.execute("VACUUM ANALYZE")
    seconds = time.perf_counter() - start

    stats = conn.execute("""
        WITH RECURSIVE tree (root, node, depth) AS (
            SELECT id, id, 0 FROM mn.recipes
            UNION ALL
            SELECT t.root, c.child_recipe_id, t.depth + 1
            FROM tree t JOIN mn.recipe_components c ON c.parent_recipe_id = t.node)
        SELECT max(depth), (SELECT count(*) FROM mn.recipe_components),
               (SELECT count(*) FROM mn.ingredients), (SELECT count(*) FROM onem.ingredients)
        FROM tree""").fetchone()
    size = {s: int(conn.execute(
        "SELECT sum(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = %s AND c.relkind = 'r'", (s,)).fetchone()[0]) for s in ("onem", "mn")}
    return {"seconds": seconds, "max_depth": stats[0], "links": stats[1],
            "mn_ingredients": stats[2], "onem_ingredients": stats[3], "bytes": size}


def time_query(conn: psycopg.Connection, sql: str, params_list: list[dict]) -> float:
    """Median client-side milliseconds, including the round trip and fetching rows."""
    times = []
    for params in params_list:
        start = time.perf_counter()
        conn.execute(sql, params).fetchall()
        times.append((time.perf_counter() - start) * 1000)
    return statistics.median(times)


def explain(conn: psycopg.Connection, sql: str, params: dict) -> str:
    plan = conn.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql, params).fetchone()[0][0]
    hit = plan["Plan"].get("Shared Hit Blocks", 0) + plan["Plan"].get("Shared Read Blocks", 0)
    return f"{plan['Plan']['Node Type']}, {plan['Execution Time']:.2f} ms, {hit} buffers"


def time_writes(conn: psycopg.Connection, n: int, repeat: int, rng: random.Random) -> dict:
    """Saving a dish (1→M: 8 ingredient rows; M:N: 8 rows plus two links, which run the
    cycle trigger), and linking two existing recipes (the trigger walks everything below
    the child). Each write is rolled back."""
    out = {"onem_save": [], "mn_save": [], "mn_link": [], "mn_link_rejected": []}
    deep = conn.execute("""
        SELECT parent_recipe_id, child_recipe_id, user_id FROM mn.recipe_components
        ORDER BY parent_recipe_id DESC LIMIT %s""", (repeat,)).fetchall()
    for i in range(repeat):
        uid = rng.randint(1, USERS)
        # Two existing recipes with the same owner (owner of id g is g % USERS + 1).
        kids = {uid - 1 + USERS * rng.randint(1, n // USERS - 1) for _ in range(2)}
        for kind in ("onem", "mn"):
            start = time.perf_counter()
            with conn.transaction(force_rollback=True):
                conn.execute(f"INSERT INTO {kind}.recipes VALUES (%s, %s, 'new dish')", (n + 1, uid))
                conn.execute(f"""INSERT INTO {kind}.ingredients (recipe_id, position, name, quantity, unit, raw_text)
                                 SELECT %s, p, 'ing_001', 1, 'g', '1 g ing_001' FROM generate_series(0, 7) p""",
                             (n + 1,))
                if kind == "mn":
                    for pos, kid in enumerate(kids):
                        conn.execute("INSERT INTO mn.recipe_components VALUES (%s, %s, %s, %s)", (uid, n + 1, kid, pos))
            out[f"{kind}_save"].append((time.perf_counter() - start) * 1000)

        parent, child, owner = deep[i % len(deep)]
        # A new link from the existing parent to a lower id with the same owner: never a
        # cycle (every seeded link points to a lower id), but the trigger still walks it.
        start = time.perf_counter()
        with conn.transaction(force_rollback=True):
            conn.execute("INSERT INTO mn.recipe_components VALUES (%s, %s, %s, 99) ON CONFLICT DO NOTHING",
                         (owner, parent, child - USERS if child > USERS else child))
        out["mn_link"].append((time.perf_counter() - start) * 1000)
        # The reverse of an existing link: always a cycle, so the trigger must reject it.
        start = time.perf_counter()
        try:
            with conn.transaction():
                conn.execute("INSERT INTO mn.recipe_components VALUES (%s, %s, %s, 99)", (owner, child, parent))
            raise AssertionError("cycle accepted")
        except psycopg.errors.CheckViolation:
            pass
        out["mn_link_rejected"].append((time.perf_counter() - start) * 1000)
    return {k: statistics.median(v) for k, v in out.items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", type=int, nargs="+", default=[1_000, 10_000, 100_000])
    ap.add_argument("--repeat", type=int, default=200, help="timed runs per query and size")
    args = ap.parse_args()
    rng = random.Random(42)
    conn = connect()
    print(conn.execute("SELECT version()").fetchone()[0])
    check_constraints(conn)

    for n in args.sizes:
        s = seed(conn, n)
        print(f"\n## {n:,} recipes ({n // USERS:,} per user), seeded in {s['seconds']:.1f} s")
        print(f"links {s['links']:,}, max nesting depth {s['max_depth']}, ingredient rows: "
              f"M:N {s['mn_ingredients']:,} vs 1→M {s['onem_ingredients']:,}; table+index size: "
              f"M:N {s['bytes']['mn'] / 1e6:.1f} MB vs 1→M {s['bytes']['onem'] / 1e6:.1f} MB")
        # Load: half the samples are recipes that have sub-recipes, the worst case for M:N.
        parents = [r[0] for r in conn.execute(
            "SELECT DISTINCT parent_recipe_id FROM mn.recipe_components ORDER BY 1").fetchall()]
        rids = [rng.choice(parents) if i % 2 else rng.randint(1, n) for i in range(args.repeat)]
        params = {
            "load": [{"rid": r} for r in rids],
            "search": [{"uid": rng.randint(1, USERS), "pat": f"%ing_{rng.randrange(VOCAB):03d}%"}
                       for _ in range(args.repeat)],
        }
        for q, sqls in QUERIES.items():  # both designs must give the same answers
            for p in params[q][:20]:
                rows = {k: [r[-4:] if q == "load" else r for r in conn.execute(sql, p).fetchall()]
                        for k, sql in sqls.items()}
                assert all(r == rows["onem"] for r in rows.values()), f"{q} differs for {p}"
        print("| query | design | median ms | plan of one run (top node, execution time, buffers) |")
        print("|---|---|---|---|")
        for q, sqls in QUERIES.items():
            for k, sql in sqls.items():
                print(f"| {q} | {k} | {time_query(conn, sql, params[q]):.2f} | {explain(conn, sql, params[q][1])} |")
        w = time_writes(conn, n, args.repeat, rng)
        print(f"| save a dish (8 ingredients) | onem | {w['onem_save']:.2f} | |")
        print(f"| save a dish (8 ingredients, 2 links) | mn | {w['mn_save']:.2f} | |")
        print(f"| link two existing recipes | mn | {w['mn_link']:.2f} | |")
        print(f"| rejected cycle | mn | {w['mn_link_rejected']:.2f} | |")


if __name__ == "__main__":
    main()
