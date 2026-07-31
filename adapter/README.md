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

* `SELECT` -- no joins, `GROUP BY`/`HAVING`, `DISTINCT`, or window/set
  operations yet.
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
    create table(:events, primary_key: false) do
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

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:clickhouse_adapter_elixir, path: "path/to/clickhouse_adapter_elixir/adapter"}
  ]
end
```

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
