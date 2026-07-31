# ChDriver

A native-protocol `DBConnection` driver for ClickHouse -- it speaks
ClickHouse's binary TCP protocol directly, rather than going over HTTP. It's
usable on its own, independent of Ecto: `ChDriver.start_link/1`,
`ChDriver.query/2..4`, `ChDriver.query!/2..4`, and `ChDriver.stream/2..4` are
the whole public surface. Everything else (`ChDriver.DBConnection`,
`ChDriver.Connection`, `ChDriver.Protocol`) is wiring underneath it.

[`adapter`](../adapter) (`Ecto.Adapters.ClickHouse`) builds an Ecto adapter on
top of this driver -- `Ecto.Adapters.ClickHouse.Connection` implements
`Ecto.Adapters.SQL.Connection` by driving a `%ChDriver.Query{}` through the
normal `DBConnection` parse/encode/execute flow.

## Usage

```elixir
{:ok, pool} = ChDriver.start_link(hostname: "localhost", port: 9000, database: "default")

{:ok, %ChDriver.Result{columns: columns, rows: rows}} =
  ChDriver.query(pool, "SELECT number FROM system.numbers LIMIT 5")

# query!/2..4 raises instead of returning {:error, reason}
result = ChDriver.query!(pool, "SELECT number FROM system.numbers WHERE number > {min:UInt64} LIMIT 5",
  [{"min", "10", 1}])

# stream/2..4 yields one wire-protocol Data block at a time instead of
# buffering the whole result; `conn` must already be checked out via
# DBConnection.run/3 or DBConnection.transaction/3
{:ok, rows} =
  DBConnection.run(pool, fn conn ->
    conn
    |> ChDriver.stream("SELECT number FROM system.numbers LIMIT 200000")
    |> Enum.take(5)
  end)
```

`start_link/1` accepts `ChDriver.Connection.connect/1`'s connection options
(`:hostname`, `:port`, `:database`, `:username`, `:password`,
`:connect_timeout`, `:recv_timeout`, `:max_buffer_size`, `:compression`) plus
the usual `DBConnection.start_link/2` pool options (`:pool_size`, `:name`,
etc.) -- it's a `DBConnection` pool of native-protocol connections, so
anything that accepts a `DBConnection` reference works as `conn`.

`query/2..4`'s `params` are `{name, raw_text}` or
`{name, raw_text, escape_rounds}` tuples binding ClickHouse native
`{name:Type}` placeholders written directly in `statement` -- see
`ChDriver.Protocol`'s and `ChDriver.Query`'s moduledocs for the full
parameter-binding story (`Ecto.Adapters.ClickHouse.Connection`'s `?`-based
binding is built on top of this).

## Compression: ch_native and ch_codec

[`ch_native`](../ch_native) (`ChNative.Block`) and [`ch_codec`](../ch_codec)
(the Rust NIF backing it) implement ClickHouse's compressed native-block wire
envelope, and this driver wires it up via the `:compression` option
(`:none`, the default, or `:lz4`) accepted by `start_link/1` and overridable
per call via `query/4`'s/`stream/4`'s `opts`. Enabling it negotiates LZ4
compression for both directions of a query's block traffic -- see
`ChDriver.Connection.connect/1` and
`ChDriver.Protocol.Messages.encode_query/2` for exactly how that negotiation
works and what it means for callers.

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:ch_driver, path: "path/to/clickhouse_adapter_elixir/ch_driver"}
  ]
end
```
