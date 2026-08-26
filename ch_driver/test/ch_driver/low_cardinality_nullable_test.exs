defmodule ChDriver.LowCardinalityNullableTest do
  @moduledoc """
  Coverage for `LowCardinality(Nullable(T))`, which does *not* use the
  leading null map every other `Nullable(T)` column does.

  Inside a `LowCardinality` dictionary, ClickHouse reserves index 0 as the
  NULL sentinel and stores a default-valued element in dictionary slot 0
  (and, in practice, a second unused default in slot 1). A row is NULL when
  its index is 0, not because of any null map -- there isn't one. Reading
  one anyway consumed dictionary bytes and raised a `FunctionClauseError`
  that dropped the connection.

  The decisive case is `''` (or `0`) being a *real* value alongside NULLs:
  it lands at its own dictionary slot with a non-zero index, proving the
  sentinel is positional and not "whatever equals the default".

  These byte strings are captured from `clickhouse-client --query
  "... FORMAT Native"` against ClickHouse 26.7, not hand-built.
  """

  use ExUnit.Case, async: true

  alias ChDriver.Protocol.NativeBlock

  defp bytes(hex), do: hex |> String.replace(~r/\s/, "") |> Base.decode16!(case: :mixed)

  describe "LowCardinality(Nullable(String))" do
    test "index 0 decodes as NULL, other indexes as their dictionary entry" do
      # SELECT CAST(x, 'LowCardinality(Nullable(String))')
      #   FROM (SELECT arrayJoin(['a', NULL, 'b', 'a']) x)
      # key version 1, flags 0x600, dict ['', '', 'a', 'b'], indexes [2,0,3,2].
      payload =
        bytes("""
        0100000000000000 0006000000000000 0400000000000000
        00 00 0161 0162
        0400000000000000 02 00 03 02
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "LowCardinality(Nullable(String))",
                 4,
                 payload
               )

      assert values == ["a", nil, "b", "a"]
    end

    test "an empty string is a real value, distinct from the NULL sentinel" do
      # SELECT CAST(x, 'LowCardinality(Nullable(String))')
      #   FROM (SELECT arrayJoin(['', NULL, 'a', '']) x)
      # dict ['', '', 'a'], indexes [1,0,2,1]: index 1 is the empty string,
      # index 0 is NULL. Both dictionary slots hold "" -- only the index
      # distinguishes them.
      payload =
        bytes("""
        0100000000000000 0006000000000000 0300000000000000
        00 00 0161
        0400000000000000 01 00 02 01
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "LowCardinality(Nullable(String))",
                 4,
                 payload
               )

      assert values == ["", nil, "a", ""]
    end

    test "a column with no NULLs still skips the reserved sentinel slots" do
      # SELECT CAST(x, 'LowCardinality(Nullable(String))')
      #   FROM (SELECT arrayJoin(['a', 'b', 'a']) x)
      # ClickHouse still reserves slots 0 and 1, so real values start at 2.
      payload =
        bytes("""
        0100000000000000 0006000000000000 0400000000000000
        00 00 0161 0162
        0300000000000000 02 03 02
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "LowCardinality(Nullable(String))",
                 3,
                 payload
               )

      assert values == ["a", "b", "a"]
    end
  end

  describe "LowCardinality(Nullable(Int32))" do
    test "zero is a real value, distinct from the NULL sentinel" do
      # SELECT CAST(x, 'LowCardinality(Nullable(Int32))')
      #   FROM (SELECT arrayJoin([0, NULL, 5]) x)
      #   SETTINGS allow_suspicious_low_cardinality_types = 1
      # dict [0, 0, 5], indexes [1,0,2]. Same positional rule as String,
      # so the sentinel is a default-valued slot of the inner type rather
      # than anything string-specific.
      payload =
        bytes("""
        0100000000000000 0006000000000000 0300000000000000
        00000000 00000000 05000000
        0300000000000000 01 00 02
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "LowCardinality(Nullable(Int32))",
                 3,
                 payload
               )

      assert values == [0, nil, 5]
    end
  end

  describe "nested under a wrapper" do
    test "Array(LowCardinality(Nullable(String))) splits rows and keeps NULLs" do
      # SELECT CAST(x, 'Array(LowCardinality(Nullable(String)))')
      #   FROM (SELECT arrayJoin([['a', NULL], ['b']]) x)
      # The LowCardinality key version is hoisted to the very front, ahead
      # of the array's own offsets.
      payload =
        bytes("""
        0100000000000000
        0200000000000000 0300000000000000
        0006000000000000 0400000000000000
        00 00 0161 0162
        0300000000000000 02 00 03
        """)

      assert {:ok, values, ""} =
               NativeBlock.decode_column_data(
                 "Array(LowCardinality(Nullable(String)))",
                 2,
                 payload
               )

      assert values == [["a", nil], ["b"]]
    end
  end
end
