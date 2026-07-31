# Ecto.Adapters.ClickHouse

An `Ecto.Adapters.SQL`-based adapter for ClickHouse that speaks ClickHouse's
native TCP protocol, not HTTP. It's backed by [`ch_driver`](../ch_driver), a
native-protocol `DBConnection` driver, rather than one of the HTTP-based
ClickHouse clients.

## What's supported

This is a minimal, early-stage adapter. It currently targets basic
`SELECT`/`INSERT` round-trips through a real `Ecto.Repo`, plus enough of
`Ecto.Adapter.Storage` and `Ecto.Adapter.Migration` to run `mix ecto.create`/
`mix ecto.drop` and straightforward `mix ecto.migrate`/`mix ecto.rollback`
migrations. In short:

* `SELECT` -- `INNER`/`LEFT JOIN` (including association-based
  `join: assoc(...)` queries) are supported; `:right`/`:full`/`:cross` and
  ClickHouse-specific ASOF/semi/anti/lateral joins are not. No
  `GROUP BY`/`HAVING`, `DISTINCT`, or window/set operations yet.
* `INSERT` -- no `:on_conflict`/`:returning` (ClickHouse has no upsert or
  `RETURNING`).
* `UPDATE`/`DELETE` via `Repo.update!/1`/`Repo.delete!/1` are not supported at
  all (ClickHouse mutates data asynchronously via `ALTER TABLE ... UPDATE`/
  `DELETE`, not synchronous SQL) -- `Repo.delete_all/2` is the one exception,
  narrowly supported (single table, no joins/`LIMIT`/`OFFSET`) since it's what
  `Ecto.Migrator`'s rollback bookkeeping needs.
* Migrations -- `CREATE TABLE`/`DROP TABLE` with plain `:add` columns. No
  `:alter` (add/remove/modify columns on an existing table), indexes, or
  constraints yet; use a raw SQL string via `execute/1` for anything else.

This list is intentionally a summary. For the exhaustive, up-to-date
breakdown of what's supported (including *why*, in each case) see the
moduledocs of `Ecto.Adapters.ClickHouse` (the top-level adapter),
`Ecto.Adapters.ClickHouse.Connection` (parameter binding), and
`Ecto.Adapters.ClickHouse.DDL` (exactly which DDL operations are safe to
auto-reverse via `change/0` versus which need explicit `up/0`/`down/0`).

## Usage

Point a repo's `adapter` at this module and configure it like any other
`Ecto.Repo`:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.ClickHouse
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  hostname: "localhost",
  port: 9000,
  database: "my_app_dev",
  username: "default",
  password: ""
```

A migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false, options: "ENGINE = MergeTree ORDER BY id") do
      add :id, :uuid, primary_key: true
      add :name, :string
      add :occurred_at, :utc_datetime
    end
  end
end
```

A schema and a query:

```elixir
defmodule MyApp.Event do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "events" do
    field :name, :string
    field :occurred_at, :utc_datetime
  end
end

MyApp.Repo.insert!(%MyApp.Event{name: "signup", occurred_at: DateTime.utc_now()})

import Ecto.Query
MyApp.Repo.all(from e in MyApp.Event, where: e.name == "signup", order_by: e.occurred_at)
```

### `ORDER BY`/primary keys are not what they are in Postgres/MySQL -- read this first

ClickHouse has no auto-increment and no unique-index enforcement at insert
time. `ORDER BY` (`MergeTree`'s sorting/indexing key, optionally narrowed by
a separate `PRIMARY KEY` clause) exists to make scans skip granules
efficiently -- it is **not** a uniqueness constraint. Duplicate values are
accepted silently, with no error.

Confirmed empirically against a live ClickHouse server (see
`test/integration/primary_key_semantics_test.exs`): plain `create
table(:things) do add :name, :string end`, with no `primary_key: false`,
does **not** raise or produce a broken column -- `Ecto.Migration` injects
its default `add :id, :bigserial, primary_key: true`, and this adapter maps
that straight onto `id UInt64 ... ORDER BY (id)`, which is valid DDL. What
actually breaks is silent and happens *after* the table exists: with no
`:on_conflict`/`:returning` support and no server-side autoincrement to
fall back on, a schema that omits `:id` from an insert (the normal
"let the database generate it" pattern from Postgres) never sends a value
for that column at all -- ClickHouse fills it with `UInt64`'s default, `0`,
for every such row. Every insert still succeeds; none of them are
distinguishable by "primary key" afterwards.

The pattern shown above -- `primary_key: false` plus an explicit,
application-supplied id (`Ecto.UUID.generate/0`, a natural key,
`System.unique_integer/1`, ...) and an explicit `options:` `ENGINE`/`ORDER
BY` once the table matters for performance -- is the one to use. See the
"`ORDER BY`/`PRIMARY KEY` is not a Postgres-style primary key" section of
`Ecto.Adapters.ClickHouse.DDL`'s moduledoc for the full empirical writeup.

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:clickhouse_adapter_elixir, path: "path/to/clickhouse_adapter_elixir/adapter"}
  ]
end
```

## Testing (test-database isolation)

Postgres/MyXQL-based Ecto suites typically reach for
`Ecto.Adapters.SQL.Sandbox`: each test runs inside a transaction that's
rolled back at the end, giving fast, fully-isolated per-test state for
free. **That pattern does not work with this adapter.** Don't discover this
the hard way -- here's the concrete finding and the recommended
alternative.

### Why Sandbox doesn't apply here

Confirmed empirically against this repo's pinned
`clickhouse/clickhouse-server:24.8` (see `docker-compose.yml`): calling
`Repo.transaction(fn -> ... end)` doesn't silently no-op -- it raises
`DBConnection.ConnectionError`, `"transactions are not supported by
ChDriver.DBConnection: :not_supported"`. `ChDriver.DBConnection`'s
`handle_begin/2`/`handle_commit/2`/`handle_rollback/2` are deliberate
unimplemented stubs (see `ch_driver/lib/ch_driver/db_connection.ex`) rather
than something pretending to work -- there is no `Ecto.Adapter.Transaction`
support to build Sandbox's checkout/rollback protocol on top of.

This isn't just a `ChDriver` gap: ClickHouse's own experimental transaction
support (`allow_experimental_transactions`, see
[clickhouse.com/docs/guides/developer/transactional](https://clickhouse.com/docs/guides/developer/transactional))
requires a ClickHouse Keeper/ZooKeeper coordination layer this repo's
`docker-compose.yml` doesn't run, only covers non-replicated `MergeTree`
tables under the `Atomic` database engine (not, e.g., the `Memory` engine
table `test/integration/repo_test.exs` uses), is explicitly documented as
experimental ("changes should be expected", unsupported on ClickHouse
Cloud), and aborts the entire transaction on *any* exception including a
typo. Not a solid enough foundation for a test helper to sit on, so it's
ruled out on substance, not merely because it isn't wired up yet.

Also non-transactional: DDL (`CREATE`/`DROP TABLE`) and MergeTree-family
table engines have no ACID transaction semantics to speak of in the first
place, which is the deeper reason Sandbox-style isolation is a dead end
for ClickHouse generally, independent of this adapter's current feature
set.

### Recommended pattern: shared tables + TRUNCATE-before-each-test reset

Create each table once per test module (in `setup_all`), `TRUNCATE` it
before every test (in `setup`), and `DROP` it once when the module
finishes (`on_exit`). This repo's own integration suite
(`test/integration/*.exs`) uses exactly this, via a small reusable helper,
`Ecto.Adapters.ClickHouse.TestCase` (`test/support/test_case.ex`):

```elixir
defmodule MyApp.SomeIntegrationTest do
  use ExUnit.Case, async: false
  import Ecto.Adapters.ClickHouse.TestCase

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
  end

  setup_clickhouse_tables TestRepo,
    widgets: "CREATE TABLE widgets (id UInt64, name String) ENGINE = MergeTree ORDER BY id"

  test "..." do
    TestRepo.insert!(%Widget{id: 1, name: "gizmo"})
    assert [%Widget{id: 1}] = TestRepo.all(Widget)
  end
end
```

This is fast (`TRUNCATE` is a metadata operation on `MergeTree`/`Memory`
tables, not a scan-and-delete) and needs no table enumeration beyond what
the test module already declares. The tradeoff: tests sharing a table
can't run `async: true` against each other, since one test's `TRUNCATE`
would race another's inserts. See
`Ecto.Adapters.ClickHouse.TestCase`'s moduledoc for the full tradeoff
writeup, including why this repo's own suite (already `async: false`
throughout, and in places -- `repo_advanced_test.exs` -- deliberately
exercising one shared pool concurrently via `Task.async_stream/3`) doesn't
need anything more.

### If you need `async: true`

Two options, in order of how much this repo would reach for them:

**Per-test-module uniquely-named database.** Use
`Ecto.Adapters.ClickHouse.storage_up/1` (`CREATE DATABASE`) in `setup_all`,
run your migrations against it, `storage_down/1` (`DROP DATABASE`) in
`on_exit`. Fully isolated, safe to run concurrent test modules against, at
the cost of a `CREATE DATABASE` + migration run + `DROP DATABASE` per test
*module* rather than a cheap `TRUNCATE` per *test* -- worth it once a
suite is large enough for `async: true` to matter, not before.

**Per-connection `CREATE TEMPORARY TABLE` shadowing**
(`Ecto.Adapters.ClickHouse.ConcurrentTestCase`,
`test/support/concurrent_test_case.ex`) -- a follow-up investigation
(`clickhouse_adapter_elixir-v7v`) confirmed, empirically against this
repo's pinned `clickhouse/clickhouse-server:24.8`, that:

* an unqualified `SELECT`/`DROP TABLE` on a connection that has run `CREATE
  TEMPORARY TABLE widgets (...)` resolves to the *temporary* table, never
  the permanent one of the same name, even with both present at once and
  other connections seeing only the permanent table's data throughout;
* `CREATE TEMPORARY TABLE` is **not** `Memory`-engine-only -- `MergeTree`,
  `ReplacingMergeTree`, `Log`, and `TinyLog` were all tested directly and
  work, so a shadow can use the same engine as the real table;
* the temp table is genuinely gone (no leak) once the owning TCP connection
  closes, with the permanent table untouched;
* `DBConnection.Ownership` (a plain connection-coordination pool module,
  unrelated to and not requiring any transaction support) can pin one
  physical pooled connection to one test process for a bounded duration,
  independent of `Ecto.Adapters.SQL.Sandbox`.

This lets `setup_clickhouse_shadow_tables/3` give each `async: true` test
its own connection with a temp-table shadow of every table it declares,
transparently hit by Ecto's normal unqualified-generated SQL, cleaned up
automatically when the connection returns to the pool for reuse by the
next test. See `Ecto.Adapters.ClickHouse.ConcurrentTestCase`'s moduledoc
for the full empirical write-up, usage example, and tradeoffs -- in
particular: `pool_size` must be >= the number of concurrently-running test
processes (same constraint Sandbox has for Postgres/MySQL), and the
`Ownership` pool's `:manual` mode means a bare `spawn/1`'d process (unlike
`Task.async/1`, which sets `$callers` automatically) needs an explicit
`DBConnection.Ownership.ownership_allow/3` to use the checked-out
connection. `test/integration/group_by_concurrent_test.exs` is a worked
proof-of-concept converted from the TRUNCATE-based
`group_by_test.exs`, running `async: true` alongside the rest of this
repo's (`async: false`) suite.

This module is additive -- it does not replace `TestCase` above, which
remains the simpler default recommendation, especially for suites that
don't need `async: true` badly enough to take on Ownership/pool-sizing
bookkeeping.

## Repo layout

This repo is split into four Mix projects, layered bottom to top:

```
ch_codec  <-  ch_native  <-  ch_driver  <-  adapter (this project)
```

* [`ch_codec`](../ch_codec) -- a Rust NIF providing raw LZ4 block compression
  and CityHash v1.0.3 checksums, the two primitives ClickHouse's native
  protocol needs for its compressed block envelope.
* [`ch_native`](../ch_native) -- `ChNative.Block`, the pure-Elixir compressed
  block envelope built on top of `ch_codec`'s NIFs. Currently unwired
  scaffolding -- see its own README.
* [`ch_driver`](../ch_driver) -- the native-protocol `DBConnection` driver
  this adapter is built on. Usable standalone, independent of Ecto.
* `adapter` (this project) -- `Ecto.Adapters.ClickHouse`, the Ecto integration
  layer on top of `ch_driver`.
