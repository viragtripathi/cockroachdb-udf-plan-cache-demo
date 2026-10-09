#!/usr/bin/env bash
# trace_reuse.sh <pgurl>
#
# psql-only proof (no compiler needed). For each UDF call shape it PREPAREs a
# statement, EXECUTEs it once to warm up, then traces 6 more EXECUTEs and
# counts how often the optimizer reused the cached plan ("reusing cached memo")
# versus rebuilt it from scratch ("rebuilding cached memo"). v26.3+ also logs
# why a cached plan was considered stale.
set -euo pipefail
url="$1"

run_case() {
  local label="$1" expr="$2"
  local out
  out="$(psql "$url" -XAtq 2>&1 <<SQL
PREPARE p AS SELECT $expr FROM core.acct WHERE acct.account_id = \$1 AND acct.bank_code = \$2;
EXECUTE p('A0000001', 'BANK01');
SET tracing = on;
EXECUTE p('A0000002', 'BANK01'); EXECUTE p('A0000003', 'BANK01'); EXECUTE p('A0000004', 'BANK01');
EXECUTE p('A0000005', 'BANK01'); EXECUTE p('A0000006', 'BANK01'); EXECUTE p('A0000007', 'BANK01');
SET tracing = off;
SELECT count(*) FILTER (WHERE message = 'reusing cached memo') || ' | '
    || count(*) FILTER (WHERE message = 'rebuilding cached memo') || ' | '
    || COALESCE(max(message) FILTER (WHERE message LIKE 'memo is stale%'), '')
FROM [SHOW TRACE FOR SESSION];
SQL
)"
  local result
  result="$(echo "$out" | grep -E '^[0-9]+ \| [0-9]+ \|' | tail -1)"
  [ -z "$result" ] && result="error | | $(echo "$out" | grep -m1 ERROR)"
  printf "| %s | \`%s\` | %s |\n" "$label" "$expr" "$result"
}

echo "| call shape | expression | reused | rebuilt | staleness reason (v26.3+) |"
echo "|---|---|---|---|---|"
run_case "no UDF (baseline)"                         "coalesce(attr_005, 0)"
run_case "nvl, NUMERIC col + int literal"            "oracompat.nvl(attr_005, 0)"
run_case "nvl, VARCHAR col + VARCHAR col"            "oracompat.nvl(attr_004, attr_004)"
run_case "nvl, VARCHAR col + string literal"         "oracompat.nvl(attr_004, 'n/a')"
run_case "nvl, VARCHAR col + literal cast to VARCHAR" "oracompat.nvl(attr_004, 'n/a'::VARCHAR)"
run_case "nvl, CHAR(1) col + string literal"         "oracompat.nvl(attr_003, 'N')"
run_case "nvl, INT4 expr + int literal"              "oracompat.nvl(attr_005::INT4, 0)"
run_case "months_between, TIMESTAMP cols (SQL)"      "oracompat.months_between(opened_at, last_txn_at)"
run_case "months_between, TIMESTAMPTZ (PL/pgSQL)"    "oracompat.months_between(opened_at::TIMESTAMPTZ, last_txn_at::TIMESTAMPTZ)"
