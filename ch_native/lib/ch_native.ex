defmodule ChNative do
  @moduledoc """
  Pure-Elixir ClickHouse native-protocol wire-format logic, built on top of
  `ch_codec`'s LZ4/CityHash primitives.

  See `ChNative.Block` for compressed block envelope encoding/decoding.

  Not currently wired into `ch_driver`: `ChDriver.Protocol.encode_query/2`
  always negotiates compression off, so this library's encode/decode paths
  are unreachable at runtime today. See `ChNative.Block`'s moduledoc for
  details and the tracking issue for wiring it up.
  """
end
