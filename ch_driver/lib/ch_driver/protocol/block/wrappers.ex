defmodule ChDriver.Protocol.Block.Wrappers do
  @moduledoc """
  Decoders for ClickHouse's wrapper/compound column types, dispatched from
  `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3`: `Nullable(T)`,
  `Array(T)`, `Map(K, V)`, `LowCardinality(T)`, and `Decimal(P, S)`.
  `Nullable`/`Array`/`Map`/`LowCardinality` each recurse back into
  `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3` for their inner
  type(s) -- this mutual recursion across the module boundary is what
  makes arbitrarily nested types like `Array(Nullable(String))` or
  `Map(String, Array(UInt32))` work for free; see
  `ChDriver.Protocol.NativeBlock`'s moduledoc for how new wrapper types
  should be added alongside these.

  `Nullable(T)`'s wire format (per ClickHouse's `ColumnNullable.cpp`,
  matching clickhouse-driver Python's `columns/nullablecolumn.py`): a
  `num_rows`-byte null map (1 = null, 0 = not null) immediately followed
  by `T`'s own column data for *all* `num_rows` rows -- including the null
  ones, whose underlying value is a meaningless placeholder (typically
  `T`'s default/zero value) and is discarded here rather than decoded.

  `Array(T)`'s wire format (per ClickHouse's `ColumnArray.cpp`
  `deserializeBinaryBulkWithMultipleStreams`, matching clickhouse-driver
  Python's `columns/arraycolumn.py`): a `num_rows`-long array of
  cumulative little-endian `UInt64` offsets (`offsets[i]` is the end
  index, exclusive, of row i's elements in the flattened value array
  below -- so `offsets[num_rows - 1]` is the total element count across
  every row), immediately followed by the flattened element values for
  *all* rows, decoded via `T`'s own `decode_column_data/3` (recursively --
  this is what lets `Array(Nullable(String))`, `Array(Array(UInt32))`,
  etc. all work).

  `Map(K, V)`'s wire format: ClickHouse's own documentation and
  `DataTypeMap.cpp` state that `Map(K, V)` is implemented internally as
  `Array(Tuple(K, V))`, and its wire encoding follows that exactly --
  `num_rows`-long cumulative little-endian `UInt64` offsets (identical to
  `Array(T)`'s own offsets), immediately followed by the *whole flattened
  key column* (`total_elements` values of `K`, decoded via `K`'s own
  `decode_column_data/3`) and then the *whole flattened value column*
  (`total_elements` values of `V`) -- i.e. a `Tuple(K, V)` column is
  serialized as one sub-stream per tuple field, back to back, not as
  interleaved (key, value) pairs. Interpreting the bytes as "all offsets,
  then all keys, then all values" round-trips `{'a':1,'b':2}` correctly,
  while an interleaved-pairs reading does not (it misaligns the `String`
  length-prefix bytes against unrelated `UInt32` value bytes). `Tuple(...)`
  itself is not supported as a directly-selectable column type -- only as
  `Map`'s implicit internal representation -- since generalizing it would
  need arbitrary-arity tuple parsing/decoding for no currently-needed
  benefit.

  `LowCardinality(T)`'s wire format is a dictionary-encoded column
  (matches `ColumnLowCardinality.cpp`/`SerializationLowCardinality.cpp`
  and clickhouse-driver Python's `columns/lowcardinalitycolumn.py`):

      key_version (UInt64) -- always 1
        (`SharedDictionariesWithAdditionalKeys`); not otherwise used here.
      index_type_and_flags (UInt64) -- the low byte is the *index type*
        (0 = UInt8, 1 = UInt16, 2 = UInt32, 3 = UInt64 -- the width of
        each per-row dictionary index below); the remaining bits are
        flags (bit 9 = HasAdditionalKeysBit, bit 10 =
        NeedUpdateDictionaryBit) that are always set for a
        single-block/non-globally-shared dictionary like this driver only
        ever sees, and aren't otherwise interpreted here.
      dictionary_size (UInt64) -- number of entries in the dictionary
        that follows, including its implicit index-0 "default value"
        entry (`""` for String, `0` for numeric types, etc).
      dictionary_size entries of `T`'s own normal column encoding (e.g.
        length-prefixed strings for `LowCardinality(String)`) -- decoded
        via `T`'s own `decode_column_data/3`, same recursive pattern as
        `Array`/`Nullable`.
      index_count (UInt64) -- the number of per-row indices that follow;
        equal to this column's `num_rows`.
      index_count little-endian unsigned integers, each `index_type`
        bytes wide, one per row -- each is an index into the dictionary
        above.

  A block with zero rows (ClickHouse sends one of these as a
  structure-only "header" block ahead of the real data block(s) for every
  query) writes zero bytes of column data for `LowCardinality`, exactly
  like every other type here. Attempting to parse the
  `key_version`/`index_type_and_flags`/`dictionary_size` fields
  unconditionally hangs/times out the connection on an empty header
  block, since there are no such bytes to read when there are no rows.

  `Decimal(P, S)`'s wire format (matches ClickHouse's
  `ColumnDecimal.h`/`DataTypeDecimalBase.h`, and clickhouse-driver
  Python's `columns/decimalcolumn.py`): a fixed-width *signed*
  little-endian integer holding the unscaled value, whose byte width is
  chosen from the precision `P` alone (not stored on the wire --
  `decimal_byte_size/1` mirrors ClickHouse's own
  `DecimalUtils::decimalWidth`/`DataTypeDecimal` precision tiers), scaled
  by `10^-S` into a `Decimal.t()`. `Decimal32(S)`/`Decimal64(S)`/
  `Decimal128(S)`/`Decimal256(S)` are just fixed-precision aliases (9, 18,
  38, and 76 respectively) for this same encoding -- see
  `ChDriver.Types.parse_decimal/1`.
  """

  alias ChDriver.Protocol.NativeBlock
  alias ChDriver.Types.Registry

  @doc false
  def decode_nullable(inner_type, num_rows, binary) do
    with {:ok, null_map, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 1, fn <<v::8>> -> v end),
         {:ok, values, rest} <- NativeBlock.decode_column_data(inner_type, num_rows, rest) do
      combined =
        null_map
        |> Enum.zip(values)
        |> Enum.map(fn
          {1, _value} -> nil
          {0, value} -> value
        end)

      {:ok, combined, rest}
    end
  end

  @doc false
  def decode_array(inner_type, num_rows, binary) do
    with {:ok, offsets, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_values, rest} <-
           NativeBlock.decode_column_data(inner_type, total_elements, rest) do
      {:ok, split_by_offsets(flat_values, offsets), rest}
    end
  end

  @doc """
  Splits `values` (the flattened element array) back into per-row lists
  using `Array(T)`'s cumulative offsets, e.g. `values = [1, 2, 3, 4, 5]`
  and `offsets = [2, 2, 5]` (row 0 has 2 elements, row 1 has 0, row 2 has
  3) splits into `[[1, 2], [], [3, 4, 5]]`.
  """
  def split_by_offsets(values, offsets) do
    {rows, _rest} =
      Enum.map_reduce(offsets, {values, 0}, fn offset, {remaining, previous_offset} ->
        {row, rest} = Enum.split(remaining, offset - previous_offset)
        {row, {rest, offset}}
      end)

    rows
  end

  @doc false
  def decode_map(key_type, value_type, num_rows, binary) do
    with {:ok, offsets, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_keys, rest} <- NativeBlock.decode_column_data(key_type, total_elements, rest),
         {:ok, flat_values, rest} <-
           NativeBlock.decode_column_data(value_type, total_elements, rest) do
      entries = Enum.zip(flat_keys, flat_values)
      rows = split_by_offsets(entries, offsets)
      {:ok, Enum.map(rows, &Map.new/1), rest}
    end
  end

  @doc false
  def decode_low_cardinality(_inner_type, 0, binary), do: {:ok, [], binary}

  def decode_low_cardinality(inner_type, _num_rows, binary) do
    with {:ok, [_key_version], rest} <-
           Registry.decode_fixed_width(binary, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, [index_type_and_flags], rest} <-
           Registry.decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, [dictionary_size], rest} <-
           Registry.decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, dictionary, rest} <-
           NativeBlock.decode_column_data(inner_type, dictionary_size, rest),
         {:ok, [index_count], rest} <-
           Registry.decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         index_byte_size = index_byte_size(index_type_and_flags),
         {:ok, indexes, rest} <-
           Registry.decode_fixed_width(rest, index_count, index_byte_size, &decode_unsigned_le/1) do
      dictionary_tuple = List.to_tuple(dictionary)
      values = Enum.map(indexes, &elem(dictionary_tuple, &1))
      {:ok, values, rest}
    end
  end

  defp index_byte_size(index_type_and_flags) do
    case Bitwise.band(index_type_and_flags, 0xFF) do
      0 -> 1
      1 -> 2
      2 -> 4
      3 -> 8
    end
  end

  defp decode_unsigned_le(<<v::unsigned-little-8>>), do: v
  defp decode_unsigned_le(<<v::unsigned-little-16>>), do: v
  defp decode_unsigned_le(<<v::unsigned-little-32>>), do: v
  defp decode_unsigned_le(<<v::unsigned-little-64>>), do: v

  @doc false
  def decode_decimal(precision, scale, num_rows, binary) do
    byte_size = decimal_byte_size(precision)
    bits = byte_size * 8

    unpack = fn chunk ->
      <<unscaled::signed-little-size(bits)>> = chunk
      sign = if unscaled < 0, do: -1, else: 1
      Decimal.new(sign, abs(unscaled), -scale)
    end

    Registry.decode_fixed_width(binary, num_rows, byte_size, unpack)
  end

  defp decimal_byte_size(precision) when precision <= 9, do: 4
  defp decimal_byte_size(precision) when precision <= 18, do: 8
  defp decimal_byte_size(precision) when precision <= 38, do: 16
  defp decimal_byte_size(_precision), do: 32
end
