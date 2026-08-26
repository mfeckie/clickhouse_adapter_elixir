# Changelog

All notable changes to `ch_driver` are documented here.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.3.0 - 2026-08-26

### Fixed

- **Silent data corruption when decoding nested `LowCardinality` columns.**
  ClickHouse hoists *every* serialization prefix in a column's type tree
  (`LowCardinality`'s dictionary key version, `Variant`'s discriminator
  mode) to the front of the column, ahead of any enclosing wrapper's data,
  rather than inline before the sub-stream it describes. Reading
  `Array(LowCardinality(String))`'s key version inline consumed the first 8
  bytes of the array's own offsets. This raised no error, it just mis-split
  the rows: `[["a","b","a"], []]` decoded as `[["a"], ["b","a"]]`. Decoding
  is now two-phase, popping prefixes depth-first before reading column
  data.

  **Anyone querying `Array(LowCardinality(...))` was silently getting wrong
  rows and should upgrade.**

- Sub-second `DateTime`/`NaiveDateTime` query parameters declared their type
  as `DateTime` while rendering fractional digits, so the server rejected
  them with `only 19 of 26 bytes was parsed`. They now declare
  `DateTime64(P)` matching the digits actually emitted.

### Added

- `DateTime64(P[, 'TZ'])` decoding. A signed little-endian Int64 tick count
  at 10^-P second resolution since the epoch; being signed (unlike plain
  `DateTime`'s UInt32) pre-epoch instants work. Decodes to a UTC
  `DateTime.t()` at precision `min(P, 6)`. The timezone argument is parsed
  and discarded, as it affects display only, never storage.
- `Variant(T1, ..., Tn)` decoding. One discriminator byte per row
  (255 = no value), then one contiguous sub-column per alternative holding
  only the rows that selected it.
- `Bool` decoding, as a single 0/1 byte to an Elixir boolean.
- Elixir maps can be bound as query parameters, as `Map(K, V)` using
  ClickHouse's `{'k':v}` literal syntax. A map with mixed value types raises
  an `ArgumentError` up front: it would need `Map(String, Variant(...))`,
  and ClickHouse cannot parse a Variant-valued Map from parameter text at
  all. To pass a Variant you must nest the casts through a member type, e.g.
  `CAST(CAST(?, 'Int32'), 'Variant(Bool, Int32, String)')`.

### Known limitations

These predate this release and are unchanged by it:

- `LowCardinality(Nullable(T))` fails to decode. Inside a
  `LowCardinality` dictionary, ClickHouse encodes nulls as an index-0
  sentinel rather than the usual leading null map, so the null map decoder
  mis-reads the dictionary. Affects it both standalone and nested, e.g.
  `Array(LowCardinality(Nullable(String)))`.
- `Tuple(...)` is not supported as a column type, raising
  `{:unsupported_type, "Tuple(...)"}`.

Both drop the connection rather than returning an error to the caller.

## 0.2.0 - 2026-08-01

### Fixed

- `Date` columns failed to decode: `NativeBlock` was missing a
  `column_codec("Date")` clause.

### Added

- A `:settings` option for passing real ClickHouse `SETTINGS` with a query.

## 0.1.1 - 2026-08-01

### Changed

- Rewrote the published documentation to be usage-focused.
- Removed an unused import warning.

## 0.1.0 - 2026-07-31

Initial release. A `DBConnection` driver speaking ClickHouse's native TCP
protocol, including its LZ4/CityHash compression NIF and compressed-block
wire envelope.
