-- Cached plans are rebuilt on every execution when a routine has more than one
-- overload and an argument's type is not OID-identical to the parameter type.
CREATE TABLE t (k INT PRIMARY KEY, v VARCHAR(20), c CHAR(1), i INT4);
INSERT INTO t VALUES (1, 'a', 'Y', 1), (2, NULL, NULL, NULL);

-- Two overloads.
CREATE FUNCTION f(x VARCHAR, y VARCHAR) RETURNS VARCHAR IMMUTABLE LANGUAGE SQL AS $$ SELECT COALESCE(x, y) $$;
CREATE FUNCTION f(x INT8, y INT8) RETURNS INT8 IMMUTABLE LANGUAGE SQL AS $$ SELECT COALESCE(x, y) $$;
-- Control: one overload (fixed for this case by #168423).
CREATE FUNCTION g(x VARCHAR, y VARCHAR) RETURNS VARCHAR IMMUTABLE LANGUAGE SQL AS $$ SELECT COALESCE(x, y) $$;

PREPARE p_literal AS SELECT f(v, 'x') FROM t WHERE k = $1;           -- STRING literal for a VARCHAR param
PREPARE p_char    AS SELECT f(c, 'N') FROM t WHERE k = $1;           -- CHAR(1) column for a VARCHAR param
PREPARE p_int4    AS SELECT f(i, 0) FROM t WHERE k = $1;             -- INT4 column for an INT8 param
PREPARE p_exact   AS SELECT f(v, 'x'::VARCHAR) FROM t WHERE k = $1;  -- control: exact types
PREPARE p_single  AS SELECT g(v, 'x') FROM t WHERE k = $1;           -- control: single overload

-- Execute once to build the cached memos.
EXECUTE p_literal(1); EXECUTE p_char(1); EXECUTE p_int4(1); EXECUTE p_exact(1); EXECUTE p_single(1);

SET tracing = on;
EXECUTE p_literal(2);
EXECUTE p_char(2);
EXECUTE p_int4(2);
EXECUTE p_exact(2);
EXECUTE p_single(2);
SET tracing = off;

-- Expected: "reusing cached memo" five times.
SELECT message FROM [SHOW TRACE FOR SESSION]
WHERE message LIKE '%cached memo%' OR message LIKE 'memo is stale%';
