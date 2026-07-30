# ChCodec

A small Rust NIF that gives Elixir two things ClickHouse's native protocol needs: raw LZ4 block compression and CityHash v1.0.3 checksums.

Used by [clickhouse_adapter_elixir](https://github.com/mfeckie/clickhouse_adapter_elixir) to talk to ClickHouse over its native TCP protocol, instead of HTTP.

## Why this exists

ClickHouse wraps every block it sends or receives in a fixed envelope:

```
[16 bytes] CityHash128 checksum (covers everything below)
[1 byte]   compression method marker
[4 bytes]  compressed size, little-endian
[4 bytes]  uncompressed size, little-endian
[...]      payload
```

Two things about this envelope make it awkward to build from off-the-shelf packages.

First, the LZ4 here isn't the LZ4 Frame format you get from the `lz4` command line tool. It's the raw LZ4 block format, with no header of its own. ClickHouse supplies its own header instead (the four fields above).

Second, the checksum isn't today's CityHash. ClickHouse froze on CityHash v1.0.3 years ago, and the algorithm's internal constants have changed since. A generic "cityhash" library on your package manager of choice will almost certainly give you the wrong answer. You need the exact old version.

ChCodec handles both, and packs the checksum into the exact byte order ClickHouse expects on the wire.

## What's in here

Three functions:

```elixir
compressed = ChCodec.lz4_compress(data)

# uncompressed_size has to come from somewhere -- ClickHouse's block
# header carries it, since the raw LZ4 format has no length prefix
{:ok, data} = ChCodec.lz4_decompress(compressed, uncompressed_size)

checksum = ChCodec.cityhash128(data)
# <<...16 bytes...>>
```

`cityhash128/1` is checked against Google's own published CityHash v1.0.3 test vectors, so you're not just trusting our word for it.

## Installation

Not on Hex yet. Once it is, add it to your deps like any other package:

```elixir
def deps do
  [
    {:ch_codec, "~> 0.1.0"}
  ]
end
```

Until then, pull it in from this repo:

```elixir
def deps do
  [
    {:ch_codec, path: "../ch_codec"}
  ]
end
```

## Precompiled builds

This is a Rust NIF, and most people don't want to install a Rust toolchain just to use a ClickHouse client. Releases are built for the common targets (macOS and Linux, both gnu and musl, arm64 and x86_64) via `rustler_precompiled`, so a normal `mix deps.get` should just download a prebuilt binary rather than compiling anything.

If you're building from source, or on a target we don't precompile for, it'll fall back to compiling the crate locally. That needs `cargo` and a stable Rust toolchain on your machine.

## Developing on this

```
mix deps.get
mix test
cd native/chcodec_native && cargo test
```
