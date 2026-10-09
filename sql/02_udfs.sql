-- Oracle-compatibility UDFs, written the way a migrated application
-- typically has them. The application SQL calls them schema-qualified,
-- e.g. oracompat.nvl(...), oracompat.months_between(...).
USE udfdemo;
CREATE SCHEMA IF NOT EXISTS oracompat;

-- NVL: one overload per type family (multiple overloads matter, see README).
CREATE OR REPLACE FUNCTION oracompat.nvl(numeric, numeric) RETURNS numeric AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1 WHEN $2 IS NOT NULL THEN $2 ELSE NULL END
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION oracompat.nvl(varchar, varchar) RETURNS varchar AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1 ELSE $2 END
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION oracompat.nvl(timestamp, timestamp) RETURNS timestamp AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1 ELSE $2 END
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION oracompat.nvl(int8, int8) RETURNS int8 AS $$
SELECT CASE WHEN $1 IS NOT NULL THEN $1 ELSE $2 END
$$ LANGUAGE SQL IMMUTABLE;

-- MONTHS_BETWEEN: SQL overload declared STRICT (RETURNS NULL ON NULL INPUT),
-- plus a PL/pgSQL overload for timestamptz.
CREATE OR REPLACE FUNCTION oracompat.months_between(t_start timestamp, t_end timestamp)
RETURNS numeric AS $$
SELECT
CASE
WHEN (t_start = date_trunc('month', t_start) + interval '1 month' - interval '1 day')
 AND (t_end = date_trunc('month', t_end) + interval '1 month' - interval '1 day')
THEN (EXTRACT(YEAR FROM t_start) - EXTRACT(YEAR FROM t_end)) * 12
   + (EXTRACT(MONTH FROM t_start) - EXTRACT(MONTH FROM t_end))
WHEN EXTRACT(DAY FROM t_start) = EXTRACT(DAY FROM t_end)
THEN (EXTRACT(YEAR FROM t_start) - EXTRACT(YEAR FROM t_end)) * 12
   + (EXTRACT(MONTH FROM t_start) - EXTRACT(MONTH FROM t_end))
ELSE (EXTRACT(YEAR FROM t_start) - EXTRACT(YEAR FROM t_end)) * 12
   + (EXTRACT(MONTH FROM t_start) - EXTRACT(MONTH FROM t_end))
   + (EXTRACT(DAY FROM t_start) - EXTRACT(DAY FROM t_end)) / 31.0
END;
$$ LANGUAGE SQL IMMUTABLE RETURNS NULL ON NULL INPUT;

CREATE OR REPLACE FUNCTION oracompat.months_between(t_start timestamptz, t_end timestamptz)
RETURNS numeric AS $$
BEGIN
  RETURN oracompat.months_between(t_start::timestamp, t_end::timestamp);
END;
$$ LANGUAGE PLpgSQL STABLE RETURNS NULL ON NULL INPUT;

-- Non-admin application role, like a real app runtime user.
CREATE USER IF NOT EXISTS app_user;
GRANT CONNECT ON DATABASE udfdemo TO app_user;
GRANT USAGE ON SCHEMA core, oracompat TO app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO app_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA oracompat TO app_user;
