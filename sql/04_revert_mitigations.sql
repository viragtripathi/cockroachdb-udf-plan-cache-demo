-- Restores the UDFs to their original definitions from sql/02_udfs.sql.
USE udfdemo;
ALTER FUNCTION oracompat.months_between(timestamp, timestamp) RETURNS NULL ON NULL INPUT;
DROP FUNCTION IF EXISTS oracompat.nvl(varchar, text);
DROP FUNCTION IF EXISTS oracompat.nvl(char, text);
