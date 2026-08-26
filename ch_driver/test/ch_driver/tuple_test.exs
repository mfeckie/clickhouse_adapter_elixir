defmodule ChDriver.TupleTest do
  @moduledoc """
  Coverage for `Tuple(...)` columns, which were previously rejected outright
  with `{:unsupported_type, "Tuple(...)"}`.

  A tuple is stored element-wise, not row-wise: every row's first element
  contiguously, then every row's second, and so on -- the same layout as a
  block of independent columns sharing a row count. Elements may be named
  (`Tuple(a Int32, b String)`), in which case the name precedes the type and
  is discarded here, since decoding produces positional Elixir tuples.

  Like any other wrapper, a tuple's elements can contribute hoisted
  serialization prefixes, which appear at the very front of the column
  ahead of the tuple's own data.

  These byte strings are captured from `clickhouse-client --query
  "... FORMAT Native"` against ClickHouse 26.7, not hand-built.
  """

  use ExUnit.Case, async: true

  alias ChDriver.Protocol.NativeBlock

  defp bytes(hex), do: hex |> String.replace(~r/\s/, "") |> Base.decode16!(case: :mixed)

  describe "element-wise layout" do
    test "Tuple(Int32, Int32) reads all first elements, then all second" do
      # SELECT t::Tuple(Int32, Int32) FROM (SELECT arrayJoin([(1,2),(3,4)]) t)
      # 1, 3 then 2, 4 -- not (1,2) then (3,4).
      payload = bytes("01000000 03000000 02000000 04000000")

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data("Tuple(Int32, Int32)", 2, payload)

      assert values == [{1, 2}, {3, 4}]
    end

    test "Tuple(String, UInt8) mixes variable- and fixed-width elements" do
      # SELECT ('a',1)::Tuple(String, UInt8) FROM numbers(2)
      payload = bytes("0161 0161 01 01")

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data("Tuple(String, UInt8)", 2, payload)

      assert values == [{"a", 1}, {"a", 1}]
    end

    test "a single-row tuple decodes" do
      # SELECT CAST((1,'x'), 'Tuple(a Int32, b String)') FROM numbers(1)
      payload = bytes("01000000 0178")

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data("Tuple(a Int32, b String)", 1, payload)

      assert values == [{1, "x"}]
    end

    test "a zero-row tuple consumes nothing" do
      assert {:ok, [], "leftover"} =
               NativeBlock.decode_column_data("Tuple(Int32, String)", 0, "leftover")
    end
  end

  describe "named elements" do
    test "element names are parsed off and the tuple stays positional" do
      # SELECT CAST((1,'x'), 'Tuple(a Int32, b String)') FROM numbers(1)
      payload = bytes("01000000 0178")

      assert {:ok, [{1, "x"}], ""} =
               NativeBlock.decode_column_data("Tuple(a Int32, b String)", 1, payload)
    end
  end

  describe "nested element types" do
    test "Tuple(Int32, Map(String, Int32)) handles a comma inside an element type" do
      # SELECT CAST((1, map('k',2)), 'Tuple(Int32, Map(String, Int32))') FROM numbers(1)
      # The split must be top-level only: "Map(String, Int32)" is one element.
      payload =
        bytes("""
        01000000
        0100000000000000
        016B 02000000
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "Tuple(Int32, Map(String, Int32))",
                 1,
                 payload
               )

      assert values == [{1, %{"k" => 2}}]
    end

    test "Tuple(Nullable(String), Int32) carries a per-element null map" do
      # SELECT CAST(x, 'Tuple(Nullable(String), Int32)')
      #   FROM (SELECT arrayJoin([(NULL,1),('a',2)]) x)
      payload =
        bytes("""
        01 00
        00 0161
        01000000 02000000
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "Tuple(Nullable(String), Int32)",
                 2,
                 payload
               )

      assert values == [{nil, 1}, {"a", 2}]
    end
  end

  describe "hoisted prefixes from elements" do
    test "Tuple(Array(LowCardinality(String)), String) hoists the key version up front" do
      # SELECT CAST((['a','b','a'],'x'),
      #             'Tuple(Array(LowCardinality(String)), String)') FROM numbers(2)
      # The inner LowCardinality key version leads the whole column, ahead
      # of the array offsets -- reading it inline would eat those offsets.
      payload =
        bytes("""
        0100000000000000
        0300000000000000 0600000000000000
        0006000000000000 0300000000000000
        00 0161 0162
        0600000000000000 01 02 01 01 02 01
        0178 0178
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "Tuple(Array(LowCardinality(String)), String)",
                 2,
                 payload
               )

      assert values == [{["a", "b", "a"], "x"}, {["a", "b", "a"], "x"}]
    end
  end
end
