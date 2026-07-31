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

## Compression: the compressed block envelope and its LZ4/CityHash NIF

`ChDriver.Protocol.Block.Compressed` (the pure-Elixir compressed-block wire
envelope) and `ChDriver.Codec` (the Rust NIF backing it) together implement
ClickHouse's compressed native-block wire envelope, and this driver wires it
up via the `:compression` option (`:none`, the default, or `:lz4`) accepted
by `start_link/1` and overridable per call via `query/4`'s/`stream/4`'s
`opts`. Enabling it negotiates LZ4 compression for both directions of a
query's block traffic -- see `ChDriver.Connection.connect/1` and
`ChDriver.Protocol.Messages.encode_query/2` for exactly how that negotiation
works and what it means for callers.

### Why a custom LZ4/CityHash codec

ClickHouse wraps every block it sends or receives in a fixed envelope:

```
[16 bytes] CityHash128 checksum (covers everything below)
[1 byte]   compression method marker (0x02 = NONE, 0x82 = LZ4, 0x90 = ZSTD)
[4 bytes]  compressed size, little-endian
[4 bytes]  uncompressed size, little-endian
[...]      payload
```

`ChDriver.Protocol.Block.Compressed.encode/2` builds one of these envelopes
(`:lz4` or `:none`); `decode/1` parses one off the front of a binary,
returning the decompressed payload plus any unconsumed trailing bytes so
callers can loop over back-to-back blocks. Multiple blocks are simply
concatenated back-to-back with no additional framing.

Two things about this envelope make it awkward to build from off-the-shelf
packages, which is why `ChDriver.Codec` exists as a small Rust NIF rather
than reaching for a generic Hex dependency:

First, the LZ4 here isn't the LZ4 Frame format you get from the `lz4`
command line tool. It's the raw LZ4 block format, with no header of its
own. ClickHouse supplies its own header instead (the four fields above).

Second, the checksum isn't today's CityHash. ClickHouse froze on CityHash
v1.0.2 years ago -- a different, older algorithm than the v1.0.3 that most
modern "cityhash" packages implement, not just a different byte-packing of
the same hash. The two only agree for short inputs and diverge once the
input exceeds roughly 64 bytes, so a generic "cityhash" library on your
package manager of choice will silently give you the wrong answer for any
real payload. You need the exact old version.

`ChDriver.Codec` handles both, and packs the checksum into the exact byte
order ClickHouse expects on the wire:

```elixir
compressed = ChDriver.Codec.lz4_compress(data)

# uncompressed_size has to come from somewhere -- ClickHouse's block
# header carries it, since the raw LZ4 format has no length prefix
{:ok, data} = ChDriver.Codec.lz4_decompress(compressed, uncompressed_size)

checksum = ChDriver.Codec.cityhash128(data)
# <<...16 bytes...>>
```

`cityhash128/1` is checked against Google's own published CityHash v1.0.2
test vectors, so you're not just trusting our word for it.

### Precompiled builds

`ChDriver.Codec` is a Rust NIF, and most people don't want to install a Rust
toolchain just to use a ClickHouse client. Releases are built for the common
targets (macOS and Linux, both gnu and musl, arm64 and x86_64) via
`rustler_precompiled`, so a normal `mix deps.get` should just download a
prebuilt binary rather than compiling anything.

If you're building from source, or on a target we don't precompile for,
it'll fall back to compiling the crate locally. That needs `cargo` and a
stable Rust toolchain on your machine.

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:ch_driver, path: "path/to/clickhouse_adapter_elixir/ch_driver"}
  ]
end
```

## Developing on the Rust NIF

```
mix deps.get
mix test
cd native/ch_driver_native && cargo test
```
