-- Database-side mitigations. The application SQL does not change.
-- Revert with sql/04_revert_mitigations.sql.
USE udfdemo;

-- 1. Drop STRICT where the body already returns NULL for NULL input.
--    Without STRICT, the UDF inlines to a plain scalar expression instead of
--    a CASE that wraps a correlated subquery (which runs as a per-row
--    routine). Verify null-safety per function before applying this.
ALTER FUNCTION oracompat.months_between(timestamp, timestamp) CALLED ON NULL INPUT;

-- 2. Exact-typed overloads for common call shapes (v26.3+ only).
--    CockroachDB types a string literal as STRING (text), so a call such as
--    oracompat.nvl(varchar_col, 'x') records the argument types (VARCHAR, STRING).
--    With several nvl overloads, the cached-plan staleness check needs an
--    overload whose parameter types match those OIDs exactly. Otherwise the
--    plan is rebuilt on every execution. Add overloads only for shapes that
--    actually occur, and re-test overload resolution for your SQL corpus.
CREATE OR REPLACE FUNCTION oracompat.nvl(varchar, text) RETURNS varchar AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1 ELSE $2::varchar END
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION oracompat.nvl(char, text) RETURNS varchar AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1::varchar ELSE $2::varchar END
$$ LANGUAGE SQL IMMUTABLE;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracompat TO app_user;
