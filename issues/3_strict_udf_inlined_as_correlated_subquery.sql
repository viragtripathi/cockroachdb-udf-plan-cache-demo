-- Inlining a STRICT (RETURNS NULL ON NULL INPUT) SQL UDF wraps the body in a
-- CASE whose ELSE branch is a correlated subquery. The subquery is not
-- flattened, so it runs as a routine for every row. The same function without
-- STRICT inlines to a plain scalar expression.
CREATE TABLE t3 (k INT PRIMARY KEY, a INT);
INSERT INTO t3 SELECT i, i FROM generate_series(1, 10000) AS g(i);
ANALYZE t3;

CREATE FUNCTION add_one_strict(x INT) RETURNS INT IMMUTABLE STRICT LANGUAGE SQL AS $$ SELECT x + 1 $$;
CREATE FUNCTION add_one(x INT) RETURNS INT IMMUTABLE LANGUAGE SQL AS $$ SELECT x + 1 $$;

EXPLAIN (OPT) SELECT add_one(a) FROM t3;         -- a + 1
EXPLAIN (OPT) SELECT add_one_strict(a) FROM t3;  -- CASE ... ELSE (subquery) END

EXPLAIN ANALYZE SELECT add_one(a) FROM t3;
EXPLAIN ANALYZE SELECT add_one_strict(a) FROM t3;
