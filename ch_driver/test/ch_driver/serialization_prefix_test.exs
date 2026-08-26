defmodule ChDriver.SerializationPrefixTest do
  @moduledoc """
  Pure unit coverage for the *hoisted serialization prefix* rule described
  in `ChDriver.Protocol.NativeBlock`'s moduledoc: `LowCardinality(T)`'s
  8-byte dictionary key version and `Variant(...)`'s 8-byte discriminator
  mode are written at the very front of a column, ahead of any enclosing
  wrapper's data, rather than immediately before the sub-column they
  describe.

  These byte strings are not hand-constructed -- each is the real column
  payload captured from `clickhouse-client --query "... FORMAT Native"`
  against ClickHouse 26.7, so they pin the decoder to the server's actual
  behaviour rather than to our reading of it.

  This is a regression test for a silent data-corruption bug: reading
  `Array(LowCardinality(String))`'s key version *inline* (where the type
  nesting suggests) consumes the first 8 bytes of the array's own offsets
  instead. That doesn't fail -- it mis-splits the rows, so
  `[['a','b','a'], []]` came back as `[['a'], ['b','a']]`.
  """

  use ExUnit.Case, async: true

  alias ChDriver.Protocol.NativeBlock

  defp bytes(hex), do: hex |> String.replace(~r/\s/, "") |> Base.decode16!(case: :mixed)

  describe "LowCardinality prefix hoisting" do
    test "Array(LowCardinality(String)) splits rows on the real offsets, not the key version" do
      # Captured from: CREATE TABLE t (id UInt32, xs Array(LowCardinality(String)));
      #               INSERT INTO t VALUES (1, ['a','b','a']), (2, []);
      #               SELECT xs FROM t ORDER BY id
      # Layout: [LC key version=1][offsets 3,3][index flags][dict size 3]
      #         ["", "a", "b"][index count 3][indexes 1,2,1]
      data =
        bytes("""
        0100000000000000
        03000000000000000300000000000000
        0006000000000000
        0300000000000000
        00 0161 0162
        0300000000000000
        010201
        """)

      assert {:ok, values, <<>>} =
               NativeBlock.decode_column_data("Array(LowCardinality(String))", 2, data)

      assert values == [["a", "b", "a"], []]
    end

    test "a top-level LowCardinality(String) still decodes, with its prefix read first" do
      # Captured from: SELECT arrayJoin(['a','b'])::LowCardinality(String)
      data =
        bytes("""
        0100000000000000
        0006000000000000
        0300000000000000
        00 0161 0162
        0200000000000000
        0102
        """)

      assert {:ok, ["a", "b"], <<>>} =
               NativeBlock.decode_column_data("LowCardinality(String)", 2, data)
    end

    test "Map(LowCardinality(String), LowCardinality(String)) hoists both prefixes up front" do
      # Captured from: SELECT map(CAST('k','LowCardinality(String)'),
      #                           CAST('v','LowCardinality(String)'))
      # Both LC key versions precede the map's offsets.
      data =
        bytes("""
        0100000000000000
        0100000000000000
        0100000000000000
        0006000000000000 0200000000000000 00 016b
        0100000000000000 01
        0006000000000000 0200000000000000 00 0176
        0100000000000000 01
        """)

      assert {:ok, [%{"k" => "v"}], <<>>} =
               NativeBlock.decode_column_data(
                 "Map(LowCardinality(String), LowCardinality(String))",
                 1,
                 data
               )
    end
  end

  describe "Variant prefix hoisting and discriminators" do
    @variant "Variant(Bool, Int32, String)"

    test "each alternative's sub-column holds only the rows that selected it" do
      # Captured from: SELECT arrayJoin([CAST(true, ...), CAST(42::Int32, ...),
      #                                  CAST('hi', ...), CAST(NULL, ...)])
      # Layout: [mode=0][discriminators 0,1,2,255][Bool: 01][Int32: 42]
      #         [String: 'hi']
      data =
        bytes("""
        0000000000000000
        000102ff
        01
        2a000000
        026869
        """)

      assert {:ok, values, <<>>} = NativeBlock.decode_column_data(@variant, 4, data)
      assert values == [true, 42, "hi", nil]
    end

    test "an alternative no row selected contributes zero bytes" do
      # Captured from a table where every row holds the Int32 alternative:
      # the Bool and String sub-columns are absent entirely.
      data =
        bytes("""
        0000000000000000
        0101010101
        0000000001000000020000000300000004000000
        """)

      assert {:ok, [0, 1, 2, 3, 4], <<>>} = NativeBlock.decode_column_data(@variant, 5, data)
    end

    test "an all-NULL Variant column reads no sub-column bytes at all" do
      # Captured from: SELECT CAST(NULL, 'Variant(Bool, Int32, String)')
      data = bytes("0000000000000000 ff")

      assert {:ok, [nil], <<>>} = NativeBlock.decode_column_data(@variant, 1, data)
    end

    test "Map(String, Variant(...)) hoists the Variant's mode ahead of the map offsets" do
      # Captured from: SELECT map('k', CAST(1::Int32, 'Variant(Bool, Int32, String)'))
      data =
        bytes("""
        0000000000000000
        0100000000000000
        016b
        01
        01000000
        """)

      assert {:ok, [%{"k" => 1}], <<>>} =
               NativeBlock.decode_column_data("Map(String, #{@variant})", 1, data)
    end

    test "Array(Variant(...)) hoists the Variant's mode ahead of the array offsets" do
      # Captured from: CREATE TABLE t (id UInt32, vs Array(Variant(...)));
      #               INSERT INTO t VALUES (1, [true, 42, 'hi']), (2, []);
      data =
        bytes("""
        0000000000000000
        03000000000000000300000000000000
        000102
        01
        2a000000
        026869
        """)

      assert {:ok, [[true, 42, "hi"], []], <<>>} =
               NativeBlock.decode_column_data("Array(#{@variant})", 2, data)
    end

    test "Variant(Int32, LowCardinality(String)) hoists both its own and the inner prefix" do
      # Captured from: SELECT arrayJoin([CAST(CAST('x','LowCardinality(String)'), V),
      #                                  CAST(7::Int32, V)])
      # where V = Variant(Int32, LowCardinality(String)).
      # Layout: [variant mode=0][LC key version=1][discriminators 1,0]
      #         [Int32 sub-column: 7][LC sub-column: 'x']
      data =
        bytes("""
        0000000000000000
        0100000000000000
        0100
        07000000
        0006000000000000 0200000000000000 00 0178
        0100000000000000 01
        """)

      assert {:ok, ["x", 7], <<>>} =
               NativeBlock.decode_column_data("Variant(Int32, LowCardinality(String))", 2, data)
    end
  end

  describe "zero-row columns carry no prefix bytes" do
    test "a zero-row LowCardinality column consumes nothing" do
      assert {:ok, [], <<1, 2, 3>>} =
               NativeBlock.decode_column_data("LowCardinality(String)", 0, <<1, 2, 3>>)
    end

    test "a zero-row Variant column consumes nothing" do
      assert {:ok, [], <<1, 2, 3>>} =
               NativeBlock.decode_column_data("Variant(Bool, Int32, String)", 0, <<1, 2, 3>>)
    end
  end
end
