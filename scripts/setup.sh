#!/usr/bin/env bash
# setup.sh <pgurl> - (re)creates the udfdemo database: schema, data, and UDFs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
url="$1"
psql "$url" -Xq -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS udfdemo CASCADE" >/dev/null
psql "$url" -Xq -v ON_ERROR_STOP=1 -f "$HERE/../sql/01_schema.sql" >/dev/null 2>&1
psql "$url" -Xq -v ON_ERROR_STOP=1 -f "$HERE/../sql/02_udfs.sql" >/dev/null 2>&1
echo "udfdemo ready on $(psql "$url" -XAtqc 'SELECT version()' | awk '{print $3}')"
