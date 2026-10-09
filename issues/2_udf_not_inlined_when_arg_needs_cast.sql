-- A SQL UDF is not inlined when an argument needs an implicit cast to the
-- parameter type, e.g. a VARCHAR(n) column for a VARCHAR parameter or a
-- DECIMAL(p,s) column for a DECIMAL parameter. The UDF then runs as a routine
-- for every row, and its body is re-optimized on each invocation (#166781).
CREATE TABLE t2 (k INT PRIMARY KEY, v VARCHAR(20), w VARCHAR, n DECIMAL(20,4), m DECIMAL);
INSERT INTO t2 SELECT i, 'v' || i::STRING, 'w' || i::STRING, i::DECIMAL, i::DECIMAL FROM generate_series(1, 10000) AS g(i);
ANALYZE t2;

CREATE FUNCTION fv(x VARCHAR) RETURNS VARCHAR IMMUTABLE LANGUAGE SQL AS $$ SELECT x || '!' $$;
CREATE FUNCTION fd(x DECIMAL) RETURNS DECIMAL IMMUTABLE LANGUAGE SQL AS $$ SELECT x + 1 $$;

-- Inlined (unconstrained columns): projections show w || '!' and m + 1.
EXPLAIN (OPT) SELECT fv(w), fd(m) FROM t2;
-- Not inlined (constrained columns): projections show fv(v::VARCHAR) and fd(n::DECIMAL).
EXPLAIN (OPT) SELECT fv(v), fd(n) FROM t2;

-- Cost over 10,000 rows.
EXPLAIN ANALYZE SELECT fv(w), fd(m) FROM t2;
EXPLAIN ANALYZE SELECT fv(v), fd(n) FROM t2;
