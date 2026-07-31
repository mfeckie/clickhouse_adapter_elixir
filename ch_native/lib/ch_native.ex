defmodule ChNative do
  @moduledoc """
  Pure-Elixir ClickHouse native-protocol wire-format logic, built on top of
  `ch_codec`'s LZ4/CityHash primitives.

  See `ChNative.Block` for compressed block envelope encoding/decoding.

  Wired into `ch_driver` as opt-in wire compression: `ChDriver.Connection.connect/1`
  and `query/3` accept a `:compression` option (`:none` by default, or `:lz4`),
  which threads through to `ChDriver.Protocol.encode_query/2`,
  `encode_empty_data_packet/1`, and `decode_packet/2` -- see `ChNative.Block`'s
  moduledoc for exactly which call sites use it.
  """
end
