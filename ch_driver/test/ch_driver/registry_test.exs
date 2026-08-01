defmodule ChDriver.Types.RegistryTest do
  @moduledoc """
  Direct unit coverage for `ChDriver.Types.Registry.column_codec/1`'s scalar
  codec table -- pure decode-function coverage, decoupled from a live
  ClickHouse server (see `ChDriver.DateTest` for the live integration
  coverage of the same `Date` codec against a real server).
  """

  use ExUnit.Case, async: true

  alias ChDriver.Types.Registry

  describe "column_codec(\"Date\")" do
    test "decodes the little-endian UInt16 day count, mirroring decode_datetime/1's style" do
      assert {:fixed, 2, unpack} = Registry.column_codec("Date")

      assert unpack.(<<0::unsigned-little-16>>) == ~D[1970-01-01]
      assert unpack.(<<1::unsigned-little-16>>) == ~D[1970-01-02]
      # 2024-03-15 is 19797 days after the epoch.
      assert unpack.(<<19797::unsigned-little-16>>) == ~D[2024-03-15]
    end
  end
end
