# shellcheck shell=bash
# Statements used by the demo. Bind parameters: $1 = account_id, $2 = bank_code.
# Each UDF statement is paired with an equivalent query written without UDFs.

# 1. Single-row lookup projecting MONTHS_BETWEEN.
Q_MB_UDF='SELECT oracompat.months_between(opened_at, last_txn_at) FROM core.acct WHERE acct.account_id = $1 AND acct.bank_code = $2'
Q_MB_SQL="SELECT CASE WHEN (opened_at = date_trunc('month', opened_at) + interval '1 month' - interval '1 day') AND (last_txn_at = date_trunc('month', last_txn_at) + interval '1 month' - interval '1 day') THEN (EXTRACT(YEAR FROM opened_at) - EXTRACT(YEAR FROM last_txn_at)) * 12 + (EXTRACT(MONTH FROM opened_at) - EXTRACT(MONTH FROM last_txn_at)) WHEN EXTRACT(DAY FROM opened_at) = EXTRACT(DAY FROM last_txn_at) THEN (EXTRACT(YEAR FROM opened_at) - EXTRACT(YEAR FROM last_txn_at)) * 12 + (EXTRACT(MONTH FROM opened_at) - EXTRACT(MONTH FROM last_txn_at)) ELSE (EXTRACT(YEAR FROM opened_at) - EXTRACT(YEAR FROM last_txn_at)) * 12 + (EXTRACT(MONTH FROM opened_at) - EXTRACT(MONTH FROM last_txn_at)) + (EXTRACT(DAY FROM opened_at) - EXTRACT(DAY FROM last_txn_at)) / 31.0 END FROM core.acct WHERE acct.account_id = \$1 AND acct.bank_code = \$2"

# 2. Join + aggregate wrapped in NVL.
NVL_FROM="FROM core.acct, core.adv WHERE adv.active_flag = 'Y' AND adv.deleted_flag != 'Y' AND adv.account_id = acct.account_id AND acct.bank_code = adv.bank_code AND acct.account_id = \$1 AND acct.bank_code = \$2 GROUP BY acct.currency_code"
Q_NVL_UDF="SELECT concat((oracompat.nvl(sum(advance_amount), '0'))::STRING, '!', acct.currency_code::STRING) $NVL_FROM"
Q_NVL_CASE="SELECT concat((CASE WHEN sum(advance_amount) IS NOT NULL THEN sum(advance_amount) WHEN '0' IS NOT NULL THEN '0' ELSE NULL END)::STRING, '!', acct.currency_code::STRING) $NVL_FROM"
Q_NVL_COALESCE="SELECT concat((coalesce(sum(advance_amount), '0'))::STRING, '!', acct.currency_code::STRING) $NVL_FROM"

# 3. NVL on a VARCHAR(20) column with a string literal (multi-overload UDF).
Q_NVL_VARCHAR="SELECT oracompat.nvl(attr_004, 'n/a') FROM core.acct WHERE acct.account_id = \$1 AND acct.bank_code = \$2"

# 4. 500-row range scans, where per-row costs show up.
RANGE_WHERE="FROM core.acct WHERE acct.account_id >= \$1 AND acct.bank_code = \$2 LIMIT 500"
Q500_MB_UDF="SELECT oracompat.months_between(opened_at, last_txn_at) $RANGE_WHERE"
Q500_MB_SQL="$(printf '%s' "$Q_MB_SQL" | sed 's/ FROM core.acct WHERE .*//') $RANGE_WHERE"
# attr_005 and attr_009 are NUMERIC(20,4). These calls are plan-cache friendly
# on v26.3 (exact types) but are not inlined (implicit cast to numeric).
Q500_NVL_UDF="SELECT oracompat.nvl(attr_005, 0), oracompat.nvl(attr_009, 0) $RANGE_WHERE"
Q500_NVL_COALESCE="SELECT coalesce(attr_005, 0), coalesce(attr_009, 0) $RANGE_WHERE"
