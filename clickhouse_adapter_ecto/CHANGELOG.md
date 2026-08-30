# Changelog

All notable changes to `clickhouse_adapter_ecto` are documented here.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.0 - 2026-08-30

### Added

- `field in subquery(inner_query)` support: renders ClickHouse's plain
  non-correlated `x IN (SELECT ...)` directly. Only non-correlated
  subqueries are supported -- like `LATERAL JOIN`, this adapter has no way
  to expose an outer-query alias to an inner query, so a `subquery/1` body
  referencing the outer query's bindings isn't supported.

## 0.4.0 - 2026-08-27

### Added

- `with_cte/3` support in `all/2`: non-recursive common table expressions
  (both the `^existing_query` and `fragment(...)` forms) render onto
  ClickHouse's `WITH name AS (subquery) SELECT ...` clause. Recursive CTEs
  (`recursive_ctes(query, true)`), the Postgres-only `:materialized` option,
  and any `:operation` other than `:all` raise a clear `Ecto.QueryError`
  instead of being silently dropped -- ClickHouse has no `WITH RECURSIVE` or
  `MATERIALIZED`/`NOT MATERIALIZED` CTE modifier, and its `WITH` clause only
  ever takes a `SELECT` subquery.
- `lock: "FINAL"` support (via `from(x in X, lock: "FINAL")` or
  `Ecto.Query.lock(query, "FINAL")`): appends ClickHouse's `FINAL` modifier
  to the queried table, forcing merge-time collapsing of
  `ReplacingMergeTree`/`AggregatingMergeTree` rows at query time for that
  query only. Any other `lock:` value raises, since ClickHouse has no
  row-locking concept.

## 0.3.4 - 2026-08-26

### Changed

- Requires `ch_driver ~> 0.4`, which adds `Tuple(...)` decoding and fixes
  `LowCardinality(Nullable(T))` columns dropping the connection. Both are
  selectable through this adapter (verified via `Repo.query/2` and a schema
  field through `Repo.all/1`), so the constraint moves with them.

## 0.3.3 - 2026-08-26

### Changed

- Requires `ch_driver ~> 0.3`. The `:utc_datetime_usec` migration type
  already generated `DateTime64(6)` DDL, so selecting such a column back
  failed on ch_driver 0.2, which could not decode `DateTime64`. That release
  also fixes silent row mis-splitting on `Array(LowCardinality(...))`
  columns; see ch_driver's changelog.

### Fixed

- Documentation: the Usage section defined a repo and its config but never
  started it, so following it verbatim left the connection pool unstarted
  and every query failing with `could not lookup Ecto repo ... because it
  was not started or it does not exist`. Now shows the `application.ex`
  supervision-tree step, plus the `config :my_app, ecto_repos: [...]` the
  `mix ecto.*` tasks warn about when missing.

## 0.3.2 - 2026-08-03

### Changed

- Trimmed the README for Hex.

## 0.3.1 - 2026-08-01

### Changed

- Requires `ch_driver ~> 0.2`, which fixes `Date` decoding. The adapter's
  `:date` migration column type already exposed that bug.
- Supports a `:settings` option for passing real ClickHouse `SETTINGS`.

## 0.3.0 - 2026-08-01

### Added

- `fragment/1` support.

## 0.2.0 - 2026-08-01

### Added

- A `table_options/1` migration helper for `ENGINE`, `ORDER BY`,
  `PARTITION BY` and `SETTINGS`.
- `RIGHT`, `FULL` and `CROSS` join support.
- A ClickHouse-specific error for `LATERAL` join qualifiers, which
  ClickHouse does not support.

### Changed

- Rewrote the published documentation with real usage examples.

## 0.1.0 - 2026-07-31

Initial release. An `Ecto.Adapters.SQL`-based adapter for ClickHouse,
speaking its native TCP protocol via `ch_driver`.
