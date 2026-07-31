# ChDriver

A native-protocol `DBConnection` driver for ClickHouse -- it speaks
ClickHouse's binary TCP protocol directly, rather than going over HTTP. It's
usable on its own, independent of Ecto: `ChDriver.start_link/1` and
`ChDriver.query/2..4` are the whole public surface. Everything else
(`ChDriver.DBConnection`, `ChDriver.Connection`, `ChDriver.Protocol`) is
wiring underneath it.

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
```

`start_link/1` accepts `ChDriver.Connection.connect/1`'s connection options
(`:hostname`, `:port`, `:database`, `:username`, `:password`,
`:connect_timeout`, `:recv_timeout`) plus the usual `DBConnection.start_link/2`
pool options (`:pool_size`, `:name`, etc.) -- it's a `DBConnection` pool of
native-protocol connections, so anything that accepts a `DBConnection`
reference works as `conn`.

`query/2..4`'s `params` are `{name, raw_text}` or
`{name, raw_text, escape_rounds}` tuples binding ClickHouse native
`{name:Type}` placeholders written directly in `statement` -- see
`ChDriver.Protocol`'s and `ChDriver.Query`'s moduledocs for the full
parameter-binding story (`Ecto.Adapters.ClickHouse.Connection`'s `?`-based
binding is built on top of this).

## Compression: ch_native and ch_codec

[`ch_native`](../ch_native) (`ChNative.Block`) and [`ch_codec`](../ch_codec)
(the Rust NIF backing it) implement ClickHouse's compressed native-block wire
envelope. That machinery is currently **not wired into this driver**:
`ChDriver.Protocol.encode_query/2` hardcodes compression off, so every Data
block sent or received today is a plain, un-enveloped Native block rather
than one wrapped by `ChNative.Block`. Wiring up compression negotiation is
tracked as a follow-up (see `ch_native`'s README and moduledoc for the
current state of that scaffolding).

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:ch_driver, path: "path/to/clickhouse_adapter_elixir/ch_driver"}
  ]
end
```
