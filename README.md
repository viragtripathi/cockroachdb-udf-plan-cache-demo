# Prepared statements calling SQL UDFs on CockroachDB: why plans are not reused, and how to fix it without changing the application

This repo reproduces a planning-overhead problem that shows up when an application migrated from Oracle runs on CockroachDB. The application in question is a C/C++ program that uses libpq, prepares each statement once with `PQprepare`, executes it many times with `PQexecPrepared`, and leans on Oracle-compatibility SQL UDFs such as `nvl` and `months_between`.

Symptoms:

- Any statement that calls a UDF is much slower than the same statement written as plain SQL, and nearly all of the difference is planning time.
- The DB Console shows **Generic Query Plan = No** for every execution of the UDF statements. The equivalent inline SQL shows 5 custom plans, then a reused generic plan.
- `EXPLAIN (OPT, VERBOSE)` shows that the UDFs are inlined, and execution time is about the same in both versions.

Everything here uses a generic, anonymized schema: a wide `account_master` table, an `account_advance` table, synonym-style views over both, and an `oracompat` schema of UDFs.

## TL;DR

| # | Finding | Versions | Fix without app changes? |
|---|---|---|---|
| 1 | **Bug:** a prepared statement that calls a UDF by name is re-planned from scratch on every execution, and generic plans are never used. The cached-plan staleness check compares the UDF version against an overload resolved by name, which never has a version, so the check always fails. | at least 25.4 to 26.2 (verified in source). Reproduced on **26.2.7**, the newest 26.2 patch. | **Upgrade to v26.3.0+.** Bug [#162055](https://github.com/cockroachdb/cockroach/issues/162055), fixed by [#162057](https://github.com/cockroachdb/cockroach/pull/162057). Not backported. |
| 2 | `plan_cache_mode = force_generic_plan` does **not** help before 26.3. The console reports generic plans, but each one is rebuilt from scratch on every execution. | ≤ 26.2 | No. Upgrade. |
| 3 | On 26.2, the extended protocol (`PQexecPrepared`) adds a **second** staleness check at Bind time ([#152791](https://github.com/cockroachdb/cockroach/issues/152791)). It fails the same way and triggers another full optbuild, which is **not** counted as planning latency. Client latency therefore grows by about 2x the planning time shown in the console. | 26.2, and 26.3 for gap 4 | Follows from 1 and 4. |
| 4 | **Remaining gap on 26.3:** if a UDF has **several overloads** and an argument's type is not OID-identical to a parameter type, the plan is still rebuilt every time. The most common case is `nvl(varchar_col, 'literal')`, because CockroachDB types the literal as STRING. Others are CHAR(n) columns and INT4 values passed to int8 parameters. [#168423](https://github.com/cockroachdb/cockroach/pull/168423) fixed this for single-overload UDFs only. | 26.3.2 | **Yes, partly.** Add exact-typed overloads, e.g. `nvl(varchar, text)` (`sql/03_mitigations.sql`). |
| 5 | **UDFs are not inlined when an argument needs an implicit cast.** For example, a `VARCHAR(20)` or `NUMERIC(20,4)` column passed to an unconstrained `varchar` or `numeric` parameter. The UDF then runs as a routine for every row, and its body is re-optimized on each call. | all | No DB-side fix. Needs an engineering change. |
| 6 | `RETURNS NULL ON NULL INPUT` (STRICT) makes the inlined body a `CASE` that wraps a correlated subquery, which runs as a per-row routine. It does not affect plan caching. | all | **Yes.** `ALTER FUNCTION ... CALLED ON NULL INPUT` when the body is already null-safe. |

**Bottom line:** on v26.3.x, the statements that motivated this repro plan as fast as their inline-SQL equivalents with no application change. That's about 30 to 40 µs with a generic plan, versus about 3.5 ms on 26.2.7 (single node). Gaps 4 and 5 still matter for a large Oracle-compat UDF library. Gap 4 has a DB-side mitigation; gap 5 needs a product fix.

## Results

Each version runs as a single-node container on the same laptop, via `make demo`. A run is one libpq connection that prepares once and executes 1,000 times (single-row statements) or 200 times (500-row statements). Server-side numbers come from `crdb_internal.statement_statistics`, filtered to the run's `application_name`. Absolute numbers will differ on real clusters; the relative differences are what matter. Full output is in [`results/before.md`](results/before.md) (v26.2.7) and [`results/after.md`](results/after.md) (v26.3.2).

### The bug (findings 1 to 3)

| statement | v26.2.7 generic plans | v26.2.7 avg planning | v26.2.7 client avg | v26.3.2 generic plans | v26.3.2 avg planning | v26.3.2 client avg |
|---|---|---|---|---|---|---|
| `oracompat.months_between(...)`, single-row lookup, `auto` | 0 / 1000 | 3,397 µs | 7,566 µs | 995 / 1000 | **31 µs** | 539 µs |
| same logic written inline, `auto` | 995 / 1000 | 61 µs | 380 µs | 995 / 1000 | 71 µs | 440 µs |
| `oracompat.nvl(sum(x), '0')`, join + group by, `auto` | 0 / 1000 | 3,600 µs | 7,853 µs | 0 / 1000 \* | **187 µs** | 595 µs |
| same with inline `CASE`, `auto` | 995 / 1000 | 57 µs | 636 µs | 0 / 1000 \* | 197 µs | 608 µs |
| same with `COALESCE`, `auto` | 995 / 1000 | 37 µs | 452 µs | 0 / 1000 \* | 212 µs | 640 µs |
| `months_between` UDF, `force_generic_plan` | 1000 / 1000 | 2,988 µs | 6,700 µs | 1000 / 1000 | **26 µs** | 509 µs |
| `nvl` UDF, `force_generic_plan` | 1000 / 1000 | 3,670 µs | 8,086 µs | 1000 / 1000 | **38 µs** | 433 µs |
| `nvl` UDF, `force_generic_plan` as a **role default**, non-admin user | 1000 / 1000 | 3,433 µs | 7,527 µs | 1000 / 1000 | **36 µs** | 435 µs |

\* On v26.3.2, `auto` kept custom plans for the join query whether or not it used a UDF. Without bind values, the generic plan's estimated cost was higher than the custom plans' average. Those custom plans are still built from the cached memo, so the UDF version now behaves exactly like the inline versions. Use `force_generic_plan` if you want generic plans.

On v26.2.7 the client sees about twice the planning time. That's the extra Bind-time rebuild from finding 3. The same UDF statements on a 3-region CockroachDB Cloud cluster (v26.2.7) planned in **7.9 to 9.2 ms**, against about 300 µs for the inline versions.

### Remaining gaps on v26.3.2 (findings 4 to 6)

| scenario (v26.3.2) | before | after a DB-side change (same app SQL) |
|---|---|---|
| `oracompat.nvl(varchar_col, 'n/a')` with 4 `nvl` overloads, `force_generic_plan` | 1000/1000 "generic", but **2,798 µs** planning and 6,290 µs client, because the plan is rebuilt every time | add `nvl(varchar, text)`: **19 µs** planning, 416 µs client |
| `months_between` declared STRICT, 500 rows | **31,644 µs** run | `ALTER FUNCTION ... CALLED ON NULL INPUT`: **1,173 µs** run (inline SQL is 860 µs) |
| `nvl(numeric_20_4_col, 0)` twice, 500 rows (not inlined) | **14,152 µs** run, 199,362 UDF body executions | no DB-side fix. `COALESCE` runs in 415 µs. |

### Proof without a benchmark: reused vs rebuilt

`make trace` (psql only) prepares a statement per call shape and traces 6 executions. It counts the optimizer's `reusing cached memo` and `rebuilding cached memo` events. One rebuild is expected: that's `auto` building its generic plan after 5 custom plans.

| call shape | v26.2.7 reused / rebuilt | v26.3.2 reused / rebuilt | v26.3.2 staleness reason |
|---|---|---|---|
| no UDF (`coalesce`) | 5 / 1 | 5 / 1 | |
| `nvl(numeric_col, 0)` | 0 / 6 | 5 / 1 | |
| `nvl(varchar_col, varchar_col)` | 0 / 6 | 5 / 1 | |
| `nvl(varchar_col, 'n/a')` | 0 / 6 | **0 / 6** | routine name resolved to different overload |
| `nvl(varchar_col, 'n/a'::VARCHAR)` | 0 / 6 | 5 / 1 | |
| `nvl(char1_col, 'N')` | 0 / 6 | **0 / 6** | routine name resolved to different overload |
| `nvl(int4_expr, 0)` | 0 / 6 | **0 / 6** | routine name resolved to different overload |
| `months_between(ts, ts)` (SQL) | 0 / 6 | 5 / 1 | |
| `months_between(tstz, tstz)` (PL/pgSQL) | 0 / 6 | 5 / 1 | |

## Root cause analysis

### Finding 1: the staleness check always fails for UDFs (≤ 26.2)

Before reusing a cached memo, the optimizer calls `Memo.IsStale`, which calls `Metadata.CheckDependencies`. For each routine referenced by name, 26.2 re-resolves the name and requires the overload's version to match the version recorded when the plan was built ([`metadata.go#L627`](https://github.com/cockroachdb/cockroach/blob/00273bd1ed9c4fbf59f1f6494a9b0d2158759959/pkg/sql/opt/metadata.go#L579-L630)):

```go
if err != nil || toCheck.Oid != overload.Oid || toCheck.Version != overload.Version {
    return false, maybeSwallowMetadataResolveErr(err)
}
```

Name resolution builds the overload from the schema descriptor's *signatures* (`UDFContainsOnlySignature: true`), and `Version` is never set ([`schema_desc.go#L597-L605`](https://github.com/cockroachdb/cockroach/blob/00273bd1ed9c4fbf59f1f6494a9b0d2158759959/pkg/sql/catalog/schemadesc/schema_desc.go#L597-L605)). The check is therefore effectively `0 != version` and fails on every execution.

When a prepared memo is stale, `chooseValidPreparedMemo` discards **both** the base and generic memos and **resets the custom/generic cost history** ([`plan_opt.go#L779-L825`](https://github.com/cockroachdb/cockroach/blob/00273bd1ed9c4fbf59f1f6494a9b0d2158759959/pkg/sql/plan_opt.go#L779-L825)). `plan_cache_mode = auto` only considers a generic plan after 5 custom plans, and the count never gets past 1. Every execution does a full optbuild (resolving views, parsing and building the UDF body), normalization, placeholder assignment and optimization. The digest-based fast path in `CheckDependencies` can't help either, because the digest is only stored after a *successful* full check.

The fix ([`a23a7b01e94f`](https://github.com/cockroachdb/cockroach/commit/a23a7b01e94f), PR [#162057](https://github.com/cockroachdb/cockroach/pull/162057), labeled v26.3.0) stops comparing versions on the name-resolved overload. It always compares the version against the overload resolved by OID instead ([master `metadata.go#L587-L623`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/opt/metadata.go#L587-L623)).

### Finding 2: why force_generic_plan does not help before 26.3

With `force_generic_plan`, the generic memo is checked with the same `IsStale` call, judged stale, discarded, and rebuilt by optimizing the statement from scratch with placeholders. The statement is flagged as having used a generic plan, so the console shows "Yes", but nothing is reused.

### Finding 3: the Bind-time check doubles the cost on 26.2

v26.2 added a check during pgwire **Bind** that the prepared statement's result types haven't changed ([#152791](https://github.com/cockroachdb/cockroach/issues/152791), [`conn_executor_prepare.go#L579-L628`](https://github.com/cockroachdb/cockroach/blob/00273bd1ed9c4fbf59f1f6494a9b0d2158759959/pkg/sql/conn_executor_prepare.go#L579-L628)). It calls `IsStale()` first and runs a full optbuild only when the memo is stale, which it always is in this case. That work happens before execution starts, so it shows up in client latency but not in the statement's planning latency. Tools that use the simple protocol with SQL-level `PREPARE`/`EXECUTE`, such as psql, don't go through Bind and won't show this part.

### Finding 4: multi-overload UDFs and non-identical argument types (still open in 26.3)

The optbuilder records each argument's resolved type ([`optbuilder/routine.go#L227-L235`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/opt/optbuilder/routine.go#L227-L235)). When the function has more than one overload, the staleness check re-matches them with `MatchOid`, a strict OID comparison ([`function_definition.go#L338`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/sem/tree/function_definition.go#L338)). Type checking is more forgiving than that. `nvl(varchar_col, 'n/a')` type-checks to `nvl(varchar, varchar)`, but the recorded argument types are `(VARCHAR, STRING)`, which match no overload exactly. The memo is judged stale on every execution. [#168304](https://github.com/cockroachdb/cockroach/issues/168304) / [#168423](https://github.com/cockroachdb/cockroach/pull/168423) added a fast path for the single-overload case only ([`matchOverloadByTypes`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/opt/metadata.go#L689-L740)). Its commit message says the multi-overload case "will be addressed separately"; there was no public issue for it at the time of writing.

Mitigation: an overload whose parameter types equal the recorded argument types, e.g. `nvl(varchar, text)`, is preferred by type checking *and* found by `MatchOid`, so the plan is reused. Add these only for call shapes you actually have, and re-test overload resolution on your SQL corpus, because new overloads can change which overload gets picked or make a call ambiguous. A single polymorphic `nvl(anyelement, anyelement)` does **not** work: CockroachDB rejects `nvl(varchar, 'literal')` with "unknown signature", and `anycompatible` is not supported.

### Finding 5: casts on arguments prevent inlining

A SQL UDF is inlined only when every argument is a constant, placeholder or column reference ([`norm/inline_funcs.go#L463-L475`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/opt/norm/inline_funcs.go#L463-L475)). Passing a `VARCHAR(20)` or `NUMERIC(20,4)` column to an unconstrained parameter adds an implicit cast (`EXPLAIN (OPT, VERBOSE)` shows `nvl(attr_005:5::DECIMAL, 0)`), so the UDF is not inlined. It runs as a routine for every row, and each call re-optimizes the body ([#166781](https://github.com/cockroachdb/cockroach/issues/166781)). In the stats, the body appears as a separate statement fingerprint with one execution per row. Schemas migrated from Oracle are mostly `VARCHAR2(n)` and `NUMBER(p,s)` columns, so this affects many real calls. PostgreSQL's SQL-function inliner accepts non-volatile, cheap argument expressions, so the same calls stay inlined there.

### Finding 6: STRICT

`ConvertUDFToSubquery` wraps a STRICT function's body in `CASE WHEN arg IS NULL ... THEN NULL ELSE (subquery) END`. The subquery inside the CASE branch isn't flattened, so it stays a correlated subquery, and correlated subqueries execute as lazily planned routines ([`execbuilder/scalar.go#L804-L873`](https://github.com/cockroachdb/cockroach/blob/d30c905fff79ef825adc96bcc647f1872a90f2ff/pkg/sql/opt/exec/execbuilder/scalar.go#L804-L873)). `months_between` already returns NULL for NULL input, so `CALLED ON NULL INPUT` is safe. A comparison over 100k rows including NULLs showed identical results. Without STRICT it inlines to the same scalar `CASE` as the hand-written SQL.

## What can be done without changing the application

1. **Run v26.3.x, or v26.4 when it ships.** v26.3 is an Innovation release (GA 2026-08-19, shorter support window). On CockroachDB Cloud only Advanced can run Innovation releases. v26.4 is the next Regular release, expected in Q4 2026. If you must stay on 26.2, ask for a backport of [#162057](https://github.com/cockroachdb/cockroach/pull/162057) and [#168423](https://github.com/cockroachdb/cockroach/pull/168423). The core fix is small (+11/−6 lines in `metadata.go`).
2. **Optionally pin generic plans per role:** `ALTER ROLE app_user SET plan_cache_mode = 'force_generic_plan';` (or `ALTER ROLE ... IN DATABASE ...`). This only helps on 26.3+. Generic plans don't see bind values, so check statements that filter on skewed columns.
3. **Drop STRICT where the body is already null-safe:** `ALTER FUNCTION ... CALLED ON NULL INPUT`.
4. **Add exact-typed overloads** for the hottest multi-overload call shapes (finding 4), and test them.
5. **Find what is still affected:**
   - Statement statistics with `genericCount = 0` and high planning latency for statements that call UDFs.
   - `SET tracing = on; EXECUTE ...; SHOW TRACE FOR SESSION`, looking for `memo is stale: routine name resolved to different overload` (v26.3+ logs the reason).
   - UDF bodies showing up as their own statement fingerprints, which means the UDF was not inlined (finding 5).

Engineering asks: backport finding 1 to 26.2, make the multi-overload staleness check use the same type equivalence as type checking (finding 4), allow inlining when arguments are cheap immutable casts of columns (finding 5), and cache routine body plans ([#165832](https://github.com/cockroachdb/cockroach/issues/165832), [#166781](https://github.com/cockroachdb/cockroach/issues/166781)).

## Running it

Prerequisites: Docker or Podman with Compose, `psql`, and libpq headers plus a C compiler (macOS `brew install libpq`, Debian/Ubuntu `apt install libpq-dev`).

```bash
make up      # v26.2.7 on :26262 and v26.3.2 on :26263 (override with OLD_VERSION / NEW_VERSION)
make build   # compiles bench/pqbench (libpq PQprepare + PQexecPrepared)
make setup   # schema (50k x 223-column accounts, 150k advances), views, UDFs
make trace   # psql-only proof: reused vs rebuilt per call shape
make demo    # full matrix -> results/before.md, results/after.md (about 2-3 minutes)
make down
```

To run against your own cluster: `./scripts/setup.sh <url>`, then `./scripts/run_matrix.sh <url-to-udfdemo>`. Reading statement statistics needs an admin connection, and the scripts set `allow_unsafe_internals` for that session.

## Layout

```
sql/01_schema.sql            wide tables + synonym-style views + data (generated by tools/gen_schema.py)
sql/02_udfs.sql              Oracle-compat UDFs as an application would have them, plus app_user
sql/03_mitigations.sql       DB-side mitigations (drop STRICT, exact-typed nvl overloads)
sql/04_revert_mitigations.sql
bench/pqbench.c              libpq harness: prepare once, execute N times with bind values
scripts/queries.sh           the statements under test
scripts/run_scenario.sh      one benchmark run + its server-side statement statistics
scripts/run_matrix.sh        all scenarios for one cluster, as markdown
scripts/trace_reuse.sh       reused vs rebuilt cached plan per UDF call shape (psql only)
results/                     output from the runs above
```
