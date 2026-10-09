#!/usr/bin/env bash
# run_scenario.sh <pgurl> <label> <iterations> <sql> [setup-sql ...]
#
# Runs bench/pqbench under a unique application_name, then reads that run's
# server-side statement statistics back from CockroachDB. Prints one markdown
# table row.
#
# Columns: top-level executions, executions that used a generic plan, average
# planning and run latency of the top-level statement, client-side average
# latency, and executions of nested UDF body statements (non-inlined UDFs run
# their body as separate statements, which shows up here). Set STATS_URL to
# read statistics with a different (admin) connection than the benchmark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
url="$1"; label="$2"; iters="$3"; sql="$4"; shift 4

app="demo_${label}_$(date +%s)_$RANDOM"
read -r client_avg _ _ < <(PGAPPNAME="$app" "$HERE/../bench/pqbench" "$url" "$sql" "$iters" "$@")

# SQL stats are ingested asynchronously, so poll until every execution
# has been recorded (or the count stops changing).
read_stats() {
  psql "${STATS_URL:-$url}" -XAtq -F ' ' <<SQL
SET allow_unsafe_internals = true;
WITH s AS (
  SELECT metadata->>'query' AS q,
         (statistics->'statistics'->>'cnt')::FLOAT8 AS cnt,
         (statistics->'statistics'->>'genericCount')::FLOAT8 AS generic,
         (statistics->'statistics'->'planLat'->>'mean')::FLOAT8 AS plan_s,
         (statistics->'statistics'->'runLat'->>'mean')::FLOAT8 AS run_s
  FROM crdb_internal.statement_statistics
  WHERE app_name = '$app' AND metadata->>'query' NOT LIKE 'SET %'
)
SELECT COALESCE(sum(cnt) FILTER (WHERE q LIKE '%core.%'), 0)::INT8,
       COALESCE(sum(generic) FILTER (WHERE q LIKE '%core.%'), 0)::INT8,
       COALESCE(round(sum(plan_s * cnt) FILTER (WHERE q LIKE '%core.%') / sum(cnt) FILTER (WHERE q LIKE '%core.%') * 1e6), 0)::INT8,
       COALESCE(round(sum(run_s * cnt) FILTER (WHERE q LIKE '%core.%') / sum(cnt) FILTER (WHERE q LIKE '%core.%') * 1e6), 0)::INT8,
       COALESCE(sum(cnt) FILTER (WHERE q NOT LIKE '%core.%'), 0)::INT8
FROM s;
SQL
}
# Stop once two consecutive reads match and all executions are in, so the
# nested UDF body counts have settled too.
prev="none"; stable=0
for _ in $(seq 1 80); do
  cur="$(read_stats)"
  read -r execs generic plan_us run_us nested <<<"$cur"
  if [[ "$cur" == "$prev" ]]; then
    (( execs >= iters )) && break
    (( ++stable >= 10 )) && break
  else
    stable=0
  fi
  prev="$cur"
  sleep 0.5
done
printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
  "$label" "$execs" "$generic" "$plan_us" "$run_us" "$client_avg" "$nested"
