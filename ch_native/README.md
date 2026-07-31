# ChNative

`ChNative.Block` implements ClickHouse's compressed native-protocol block
envelope -- the wire format a Data block is wrapped in when compression is
in play:

```
[16 bytes] CityHash128 checksum, over everything below
[1 byte]   compression method marker (0x02 = NONE, 0x82 = LZ4, 0x90 = ZSTD)
[4 bytes]  compressed_size, little-endian
[4 bytes]  uncompressed_size, little-endian
[...]      payload (compressed unless method is NONE)
```

`encode/2` builds one of these envelopes (`:lz4` or `:none`); `decode/1`
parses one off the front of a binary, returning the decompressed payload plus
any unconsumed trailing bytes so callers can loop over back-to-back blocks.
Both are backed by [`ch_codec`](../ch_codec)'s NIFs -- `ChCodec.lz4_compress/1`
/`lz4_decompress/2` for the raw (headerless) LZ4 block format ClickHouse
uses, and `ChCodec.cityhash128/1` for the checksum, computed with the exact
CityHash v1.0.2 constants ClickHouse itself uses (not today's CityHash).

## Wired into ch_driver as opt-in compression

Both `encode/2` and `decode/1` are called from [`ch_driver`](../ch_driver),
gated behind its `:compression` option (`:none` by default, `:lz4` to opt
in). `ChDriver.Protocol.Messages.encode_query/2` negotiates compression with
the server via the Query packet's compression flag; outbound and inbound
Data/ProfileEvents blocks are then routed through `encode/2`/`decode/1`
respectively -- see `ChNative.Block`'s own moduledoc for the exact call
sites.

## Relationship to ch_codec

`ch_native` depends on `ch_codec` (a Rust NIF, built via `rustler_precompiled`)
for the LZ4 and CityHash primitives, but the two are kept as separate Mix
projects rather than merged. The reason is release-versioning, not code
size: `ch_codec`'s `RustlerPrecompiled` configuration derives its precompiled-
binary download URL from a version-specific release tag
(`ch_codec-v#{version}`), tied to `ch_codec`'s own `@version` and its own
release pipeline. If `ch_codec` were folded into `ch_native` as one project,
every pure-Elixir-only change to `ChNative.Block` would sit under that same
version, and bumping it for an Elixir-only change would send
`RustlerPrecompiled` looking for a NIF release tag that doesn't exist yet
(since no Rust code changed). Keeping them separate lets `ch_native`'s
version move independently of `ch_codec`'s NIF release cadence.

## Installation

Not on Hex. Pull it in from this repo with a path dependency:

```elixir
def deps do
  [
    {:ch_native, path: "path/to/clickhouse_adapter_elixir/ch_native"}
  ]
end
```
