# Ecto.Adapters.ClickHouse

[![Hex.pm](https://img.shields.io/hexpm/v/clickhouse_adapter_ecto.svg)](https://hex.pm/packages/clickhouse_adapter_ecto)

An `Ecto.Adapters.SQL` adapter for [ClickHouse](https://clickhouse.com), built
on [`ch_driver`](https://github.com/mfeckie/clickhouse_adapter_elixir/tree/main/ch_driver),
a `DBConnection` driver speaking ClickHouse's native TCP protocol (not HTTP).

Documentation: https://hexdocs.pm/clickhouse_adapter_ecto/

## Installation

```elixir
def deps do
  [
    {:clickhouse_adapter_ecto, "~> 0.3"}
  ]
end
```

## Usage

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

  @primary_key false
  schema "events" do
    field :id, :string
    field :name, :string
    field :occurred_at, :utc_datetime
  end
end

MyApp.Repo.insert!(%MyApp.Event{
  id: Ecto.UUID.generate(),
  name: "signup",
  occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
})

import Ecto.Query
MyApp.Repo.all(from e in MyApp.Event, where: e.name == "signup", order_by: e.occurred_at)
```

## What's supported

| Feature | Support |
|---|---|
| `SELECT` | `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS JOIN` (incl. `join: assoc(...)`), `GROUP BY`, `HAVING`. No ASOF/semi/anti/lateral joins, `DISTINCT`, or window/set operations. |
| `INSERT` | No `:on_conflict`/`:returning` (ClickHouse has no upsert or `RETURNING`). |
| `UPDATE`/`DELETE` | Not supported via `Repo.update!/1`/`delete!/1` -- ClickHouse mutates asynchronously via `ALTER TABLE ... UPDATE`/`DELETE`. `Repo.delete_all/2` is a narrow exception (single table, no joins/`LIMIT`/`OFFSET`), used by `Ecto.Migrator`'s rollback bookkeeping. |
| Migrations | `CREATE`/`DROP TABLE` with plain `:add` columns. No `:alter`, indexes, or constraints -- use `execute/1` for anything else. |

For the exhaustive breakdown (and why), see the moduledocs of
`Ecto.Adapters.ClickHouse`, `Ecto.Adapters.ClickHouse.Connection`, and
`Ecto.Adapters.ClickHouse.DDL`.

## `ORDER BY`/primary keys are not what they are in Postgres/MySQL

ClickHouse has no auto-increment and no unique-index enforcement at insert
time. `ORDER BY` (`MergeTree`'s sorting/indexing key) exists to make scans
skip granules efficiently -- it is **not** a uniqueness constraint, and
duplicate values are accepted silently.

In practice: use `primary_key: false` with an explicit, application-supplied
id (`Ecto.UUID.generate/0`, a natural key, `System.unique_integer/1`, ...),
as shown above, plus an explicit `options:` `ENGINE`/`ORDER BY` once the
table matters for performance. See the "`ORDER BY`/`PRIMARY KEY` is not a
Postgres-style primary key" section of `Ecto.Adapters.ClickHouse.DDL`'s
moduledoc for the full write-up.

## Testing

`Ecto.Adapters.SQL.Sandbox` doesn't work here -- this adapter has no
`Ecto.Adapter.Transaction` support (`ChDriver.DBConnection`'s
`handle_begin/2`/`handle_commit/2`/`handle_rollback/2` are deliberate
unimplemented stubs), and ClickHouse's own experimental transactions
require a Keeper/ZooKeeper coordination layer.

Instead, create each table once per test module, `TRUNCATE` it before every
test, and `DROP` it on exit. `Ecto.Adapters.ClickHouse.TestCase`
(`test/support/test_case.ex`) wraps this pattern:

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

Tests sharing a table this way can't run `async: true` against each other.
For that, see `Ecto.Adapters.ClickHouse.ConcurrentTestCase`
(per-connection temp-table shadowing) or a per-test-module database via
`storage_up/1`/`storage_down/1` -- both documented in their own moduledocs.

## Repo layout

This repo is split into two Mix projects, layered bottom to top:

```
ch_driver  <-  clickhouse_adapter_ecto (this project)
```

* [`ch_driver`](https://github.com/mfeckie/clickhouse_adapter_elixir/tree/main/ch_driver) --
  the native-protocol `DBConnection` driver this adapter is built on, usable
  standalone. Includes `ChDriver.Codec` (a Rust NIF for LZ4 compression and
  CityHash checksums) backing the driver's opt-in `:compression` option.
* `clickhouse_adapter_ecto` (this project) -- the Ecto integration layer on
  top of `ch_driver`.

## License

MIT
