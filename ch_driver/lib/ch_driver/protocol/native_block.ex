defmodule ChDriver.Protocol.NativeBlock do
  @moduledoc """
  Decodes ClickHouse's plaintext "Native" block format -- the payload of a
  Data (or wire-identical ProfileEvents) packet once compression is
  disabled (this driver always negotiates `compression: 0` in
  `ChDriver.Protocol.encode_query/2`, so blocks are never wrapped in
  `ChNative.Block`'s compressed envelope; see the design decision recorded
  in clickhouse_adapter_elixir-8a2.5).

  Format (confirmed live against ClickHouse 24.8, revision 54469, cross
  referenced against `Formats/NativeReader.cpp` at tag v24.8.14.39-lts):

      external_table_name (string -- only present when this block is the
        payload of a Data/ProfileEvents *packet*; see `decode_data_packet/1`)
      BlockInfo:
        repeated (field_num varint, value) pairs, terminated by field_num 0
          field 1 -> is_overflows (UInt8)
          field 2 -> bucket_num (Int32, little-endian)
      num_columns (varint)
      num_rows (varint)
      num_columns times:
        name (string)
        type (string)
        has_custom_serialization (UInt8 -- gated on
          DBMS_MIN_REVISION_WITH_CUSTOM_SERIALIZATION, always present at
          revision 54469; we only support has_custom == 0)
        column data (num_rows values, encoding depends on type -- see
          `decode_column_data/3`)

  Only a pragmatic subset of ClickHouse's type system is supported --
  enough to prove out `SELECT 1` / `SELECT number FROM system.numbers` and
  to skip over the columns ClickHouse's own ProfileEvents packet sends
  alongside every query result (String, DateTime, UInt64, Enum8, Int64).

  `Nullable(T)` is supported as a wrapper around any of the above: on the
  wire it is a `row_count`-byte null map (1 = null, 0 = not null,
  confirmed against ClickHouse's `ColumnNullable.cpp`
  `deserializeBinaryBulkWithMultipleStreams`) immediately followed by `T`'s
  normal column data for *all* rows -- including the null ones, whose
  underlying value is a meaningless placeholder (typically `T`'s
  default/zero value) and is discarded rather than decoded. See
  `type_dispatch/1` for how new wrapper/compound types (Array, Map, ...)
  should be added alongside `Nullable` -- each gets its own dispatch clause
  and decoder function rather than deeper `column_codec/1` special-casing.

  Also supported, following the same pattern (each confirmed live against
  ClickHouse 24.8 -- see the `decode_*` function for each for the exact
  wire-format details):

    * `Array(T)` for any `T` this module already knows how to decode
      (including nested wrappers, e.g. `Array(Nullable(String))`).
    * `Decimal(P, S)` and its fixed-precision aliases `Decimal32(S)` /
      `Decimal64(S)` / `Decimal128(S)` / `Decimal256(S)`, decoded to
      `Decimal.t()`.
    * `UUID`.
    * `LowCardinality(T)` for any scalar `T` (String, integers, etc).

  Deliberately deferred (not implemented -- see clickhouse_adapter_elixir-8a2.19's
  closing notes for why): `Map(K, V)`, `IPv4`, `IPv6`, `FixedString(N)`.
  """

  alias ChDriver.Protocol.Varint

  @doc """
  Decodes a Data/ProfileEvents *packet* body (i.e. everything after the
  packet-type varint): the external table name string, followed by a
  Native block.

  Returns `{:ok, %{table_name:, columns:, rows:}, rest}`,
  `{:incomplete, binary}`, or `{:error, reason}`.
  """
  @spec decode_data_packet(binary) :: {:ok, map, binary} | {:incomplete, binary} | {:error, term}
  def decode_data_packet(binary) do
    with {:ok, table_name, rest} <- Varint.decode_string(binary),
         {:ok, block, rest} <- decode_block(rest) do
      {:ok, Map.put(block, :table_name, table_name), rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decodes a Native block (everything after the external table name):
  BlockInfo, column count, row count, and each column's name/type/data.

  Returns `{:ok, %{columns: [{name, type}], rows: [[term]]}, rest}`,
  `{:incomplete, binary}`, or `{:error, reason}`.
  """
  @spec decode_block(binary) :: {:ok, map, binary} | {:incomplete, binary} | {:error, term}
  def decode_block(binary) do
    with {:ok, rest} <- skip_block_info(binary),
         {:ok, num_columns, rest} <- Varint.decode(rest),
         {:ok, num_rows, rest} <- Varint.decode(rest),
         {:ok, columns, column_data, rest} <- decode_columns(rest, num_columns, num_rows) do
      rows = transpose(column_data, num_rows)
      {:ok, %{columns: columns, rows: rows}, rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp skip_block_info(binary) do
    with {:ok, field_num, rest} <- Varint.decode(binary) do
      case {field_num, rest} do
        {0, rest} ->
          {:ok, rest}

        {1, <<_is_overflows::8, rest::binary>>} ->
          skip_block_info(rest)

        {2, <<_bucket_num::signed-little-32, rest::binary>>} ->
          skip_block_info(rest)

        {other, _rest} when other in [1, 2] ->
          {:incomplete, binary}

        {other, _rest} ->
          {:error, {:unsupported_block_info_field, other}}
      end
    else
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  defp decode_columns(binary, num_columns, num_rows) do
    do_decode_columns(binary, num_columns, num_rows, [], [])
  end

  defp do_decode_columns(binary, 0, _num_rows, columns_acc, data_acc) do
    {:ok, Enum.reverse(columns_acc), Enum.reverse(data_acc), binary}
  end

  defp do_decode_columns(binary, remaining, num_rows, columns_acc, data_acc) do
    with {:ok, name, rest} <- Varint.decode_string(binary),
         {:ok, type, rest} <- Varint.decode_string(rest),
         {:has_custom, <<has_custom::8, rest::binary>>} <- {:has_custom, rest},
         :ok <- ensure_no_custom_serialization(has_custom, type),
         {:ok, values, rest} <- decode_column_data(type, num_rows, rest) do
      do_decode_columns(rest, remaining - 1, num_rows, [{name, type} | columns_acc], [
        values | data_acc
      ])
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:has_custom, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_no_custom_serialization(0, _type), do: :ok

  defp ensure_no_custom_serialization(_other, type),
    do: {:error, {:unsupported_custom_serialization, type}}

  # Top-level type dispatch. Compound/wrapper types that need more than a
  # single fixed-width-or-string codec (Nullable today; Array/Map/etc in
  # future work) get their own clause here and their own decoder function
  # below -- everything else falls through to the plain `column_codec/1`
  # table. This is the extension point for new wrapper types: add a clause
  # here that pattern-matches/parses the type string, plus a `decode_*`
  # function alongside `decode_nullable/3`.
  defp decode_column_data(type, num_rows, binary) do
    case parse_nullable(type) do
      {:ok, inner_type} ->
        decode_nullable(inner_type, num_rows, binary)

      :error ->
        case parse_array(type) do
          {:ok, inner_type} ->
            decode_array(inner_type, num_rows, binary)

          :error ->
            case parse_low_cardinality(type) do
              {:ok, inner_type} ->
                decode_low_cardinality(inner_type, num_rows, binary)

              :error ->
                case parse_decimal(type) do
                  {:ok, precision, scale} ->
                    decode_decimal(precision, scale, num_rows, binary)

                  :error ->
                    case column_codec(type) do
                      {:fixed, byte_size, unpack} ->
                        decode_fixed_width(binary, num_rows, byte_size, unpack)

                      :string ->
                        decode_strings(binary, num_rows, [])

                      :unsupported ->
                        {:error, {:unsupported_type, type}}
                    end
                end
            end
        end
    end
  end

  # Strips a `Prefix(...)` wrapper down to its inner contents, given the
  # exact `"Prefix("` (including the opening paren) to match against. Not a
  # general parenthesis-balancer -- just strips the given prefix and the
  # trailing `)` -- but that's sufficient even for a parameterized inner
  # type like `Nullable(DateTime(3))`, since the outer `)` is always the
  # last byte of the whole type string.
  defp strip_wrapper(type, prefix) do
    prefix_size = byte_size(prefix)

    case type do
      <<^prefix::binary-size(prefix_size), rest::binary>> when byte_size(rest) > 0 ->
        case String.split_at(rest, byte_size(rest) - 1) do
          {inner, ")"} -> {:ok, inner}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Parses ClickHouse's `Nullable(T)` wrapper syntax, returning the inner
  # type string.
  defp parse_nullable(type), do: strip_wrapper(type, "Nullable(")

  # Parses ClickHouse's `Array(T)` wrapper syntax, returning the inner type
  # string.
  defp parse_array(type), do: strip_wrapper(type, "Array(")

  # Parses ClickHouse's `LowCardinality(T)` wrapper syntax, returning the
  # inner type string.
  defp parse_low_cardinality(type), do: strip_wrapper(type, "LowCardinality(")

  # `Nullable(T)`'s wire format (confirmed against ClickHouse's
  # `ColumnNullable.cpp` and cross-referenced with clickhouse-driver
  # Python's `columns/nullablecolumn.py`): a `num_rows`-byte null map
  # (1 = null, 0 = not null) immediately followed by `T`'s own column data
  # for *all* `num_rows` rows. The underlying value for a null row is a
  # meaningless placeholder and is discarded here rather than decoded.
  defp decode_nullable(inner_type, num_rows, binary) do
    with {:ok, null_map, rest} <- decode_fixed_width(binary, num_rows, 1, fn <<v::8>> -> v end),
         {:ok, values, rest} <- decode_column_data(inner_type, num_rows, rest) do
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

  # `Array(T)`'s wire format (confirmed against ClickHouse's
  # `ColumnArray.cpp` `deserializeBinaryBulkWithMultipleStreams`, and
  # cross-referenced with clickhouse-driver Python's
  # `columns/arraycolumn.py`): a `num_rows`-long array of cumulative
  # little-endian `UInt64` offsets (offsets[i] is the end index, exclusive,
  # of row i's elements in the flattened value array below -- so
  # `offsets[num_rows - 1]` is the total element count across every row),
  # immediately followed by the flattened element values for *all* rows,
  # decoded via `T`'s own `decode_column_data/3` (recursively -- this is
  # what lets `Array(Nullable(String))`, `Array(Array(UInt32))`, etc. all
  # work for free).
  defp decode_array(inner_type, num_rows, binary) do
    with {:ok, offsets, rest} <-
           decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_values, rest} <- decode_column_data(inner_type, total_elements, rest) do
      {:ok, split_by_offsets(flat_values, offsets), rest}
    end
  end

  # Splits `values` (the flattened element array) back into per-row lists
  # using `Array(T)`'s cumulative offsets, e.g. `values = [1, 2, 3, 4, 5]`
  # and `offsets = [2, 2, 5]` (row 0 has 2 elements, row 1 has 0, row 2 has
  # 3) splits into `[[1, 2], [], [3, 4, 5]]`.
  defp split_by_offsets(values, offsets) do
    {rows, _rest} =
      Enum.map_reduce(offsets, {values, 0}, fn offset, {remaining, previous_offset} ->
        {row, rest} = Enum.split(remaining, offset - previous_offset)
        {row, {rest, offset}}
      end)

    rows
  end

  # `Decimal(P, S)`'s wire format (confirmed against ClickHouse's
  # `ColumnDecimal.h`/`DataTypeDecimalBase.h`, and cross-referenced with
  # clickhouse-driver Python's `columns/decimalcolumn.py`): a fixed-width
  # *signed* little-endian integer holding the unscaled value, whose byte
  # width is chosen from the precision `P` alone (not stored on the wire --
  # `decimal_byte_size/1` mirrors ClickHouse's own
  # `DecimalUtils::decimalWidth`/`DataTypeDecimal` precision tiers), scaled
  # by `10^-S` into a `Decimal.t()`. `Decimal32(S)`/`Decimal64(S)`/
  # `Decimal128(S)`/`Decimal256(S)` are just fixed-precision aliases (9, 18,
  # 38, and 76 respectively) for this same encoding.
  defp decode_decimal(precision, scale, num_rows, binary) do
    byte_size = decimal_byte_size(precision)
    bits = byte_size * 8

    unpack = fn chunk ->
      <<unscaled::signed-little-size(bits)>> = chunk
      sign = if unscaled < 0, do: -1, else: 1
      Decimal.new(sign, abs(unscaled), -scale)
    end

    decode_fixed_width(binary, num_rows, byte_size, unpack)
  end

  defp decimal_byte_size(precision) when precision <= 9, do: 4
  defp decimal_byte_size(precision) when precision <= 18, do: 8
  defp decimal_byte_size(precision) when precision <= 38, do: 16
  defp decimal_byte_size(_precision), do: 32

  # Parses `Decimal(P, S)` and the `Decimal32(S)`/`Decimal64(S)`/
  # `Decimal128(S)`/`Decimal256(S)` fixed-precision aliases, returning
  # `{:ok, precision, scale}`.
  defp parse_decimal("Decimal(" <> rest) do
    case Regex.run(~r/^(\d+)\s*,\s*(\d+)\)$/, rest) do
      [_, precision, scale] -> {:ok, String.to_integer(precision), String.to_integer(scale)}
      nil -> :error
    end
  end

  defp parse_decimal("Decimal32(" <> rest), do: parse_decimal_alias(rest, 9)
  defp parse_decimal("Decimal64(" <> rest), do: parse_decimal_alias(rest, 18)
  defp parse_decimal("Decimal128(" <> rest), do: parse_decimal_alias(rest, 38)
  defp parse_decimal("Decimal256(" <> rest), do: parse_decimal_alias(rest, 76)
  defp parse_decimal(_type), do: :error

  defp parse_decimal_alias(rest, precision) do
    case Regex.run(~r/^(\d+)\)$/, rest) do
      [_, scale] -> {:ok, precision, String.to_integer(scale)}
      nil -> :error
    end
  end

  # `UUID`'s wire format (confirmed live against ClickHouse 24.8 by
  # `reinterpretAsFixedString`-ing a known UUID and comparing raw bytes
  # against its text representation): 16 bytes, laid out as the UUID's
  # standard 16 text-representation bytes with *each 8-byte half
  # byte-reversed independently* -- i.e. NOT the naive byte order, and NOT
  # a swap of the two halves either. Concretely, for UUID
  # `61f0c404-5cb3-11e7-907b-a6006ad3dba0` (standard bytes
  # `61 f0 c4 04 5c b3 11 e7 90 7b a6 00 6a d3 db a0`), ClickHouse's raw
  # in-memory/wire bytes are
  # `e7 11 b3 5c 04 c4 f0 61 a0 db d3 6a 00 a6 7b 90` -- reversing bytes
  # 0..7 and, separately, bytes 8..15 of the wire form recovers the
  # standard form byte-for-byte.
  defp decode_uuid(<<hi::binary-size(8), lo::binary-size(8)>>) do
    hex = Base.encode16(reverse_bytes(hi) <> reverse_bytes(lo), case: :lower)
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end

  defp reverse_bytes(binary) do
    binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end

  # `LowCardinality(T)`'s wire format is a dictionary-encoded column
  # (confirmed live against ClickHouse 24.8, byte-for-byte, against a real
  # `LowCardinality(String)` column with repeated and distinct values --
  # cross-referenced with `ColumnLowCardinality.cpp`/
  # `SerializationLowCardinality.cpp` and clickhouse-driver Python's
  # `columns/lowcardinalitycolumn.py`):
  #
  #     key_version (UInt64) -- always 1
  #       (`SharedDictionariesWithAdditionalKeys`); not otherwise used here.
  #     index_type_and_flags (UInt64) -- the low byte is the *index type*
  #       (0 = UInt8, 1 = UInt16, 2 = UInt32, 3 = UInt64 -- the width of
  #       each per-row dictionary index below); the remaining bits are
  #       flags (bit 9 = HasAdditionalKeysBit, bit 10 =
  #       NeedUpdateDictionaryBit) that are always set for a
  #       single-block/non-globally-shared dictionary like this driver only
  #       ever sees, and aren't otherwise interpreted here.
  #     dictionary_size (UInt64) -- number of entries in the dictionary
  #       that follows, including its implicit index-0 "default value"
  #       entry (`""` for String, `0` for numeric types, etc).
  #     dictionary_size entries of `T`'s own normal column encoding (e.g.
  #       length-prefixed strings for `LowCardinality(String)`) -- decoded
  #       via `T`'s own `decode_column_data/3`, same recursive pattern as
  #       `Array`/`Nullable`.
  #     index_count (UInt64) -- the number of per-row indices that follow;
  #       equal to this column's `num_rows`.
  #     index_count little-endian unsigned integers, each `index_type`
  #       bytes wide, one per row -- each is an index into the dictionary
  #       above.
  # A block with zero rows (ClickHouse sends one of these as a
  # structure-only "header" block ahead of the real data block(s) for every
  # query) writes zero bytes of column data for `LowCardinality`, exactly
  # like every other type here -- confirmed live: attempting to parse the
  # `key_version`/`index_type_and_flags`/`dictionary_size` fields
  # unconditionally hangs/times out the connection on an empty header
  # block, since there are no such bytes to read when there are no rows.
  defp decode_low_cardinality(_inner_type, 0, binary), do: {:ok, [], binary}

  defp decode_low_cardinality(inner_type, _num_rows, binary) do
    with {:ok, [_key_version], rest} <-
           decode_fixed_width(binary, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, [index_type_and_flags], rest} <-
           decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, [dictionary_size], rest} <-
           decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, dictionary, rest} <- decode_column_data(inner_type, dictionary_size, rest),
         {:ok, [index_count], rest} <-
           decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         index_byte_size = index_byte_size(index_type_and_flags),
         {:ok, indexes, rest} <-
           decode_fixed_width(rest, index_count, index_byte_size, &decode_unsigned_le/1) do
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

  # A pragmatic subset of ClickHouse's type system: fixed-width integer and
  # float types (by exact name), String, and a couple of common wrapper
  # types (DateTime, Enum8/Enum16) that show up in ClickHouse's own
  # ProfileEvents packets sent alongside every query result. Not a general
  # type system -- see moduledoc.
  defp column_codec("UInt8"), do: {:fixed, 1, fn <<v::unsigned-little-8>> -> v end}
  defp column_codec("UInt16"), do: {:fixed, 2, fn <<v::unsigned-little-16>> -> v end}
  defp column_codec("UInt32"), do: {:fixed, 4, fn <<v::unsigned-little-32>> -> v end}
  defp column_codec("UInt64"), do: {:fixed, 8, fn <<v::unsigned-little-64>> -> v end}
  defp column_codec("Int8"), do: {:fixed, 1, fn <<v::signed-little-8>> -> v end}
  defp column_codec("Int16"), do: {:fixed, 2, fn <<v::signed-little-16>> -> v end}
  defp column_codec("Int32"), do: {:fixed, 4, fn <<v::signed-little-32>> -> v end}
  defp column_codec("Int64"), do: {:fixed, 8, fn <<v::signed-little-64>> -> v end}
  defp column_codec("Float32"), do: {:fixed, 4, fn <<v::float-little-32>> -> v end}
  defp column_codec("Float64"), do: {:fixed, 8, fn <<v::float-little-64>> -> v end}
  defp column_codec("DateTime"), do: {:fixed, 4, &decode_datetime/1}
  defp column_codec("String"), do: :string
  defp column_codec("UUID"), do: {:fixed, 16, &decode_uuid/1}

  defp column_codec(type) do
    cond do
      String.starts_with?(type, "DateTime(") -> {:fixed, 4, &decode_datetime/1}
      String.starts_with?(type, "Enum8(") -> {:fixed, 1, fn <<v::signed-little-8>> -> v end}
      String.starts_with?(type, "Enum16(") -> {:fixed, 2, fn <<v::signed-little-16>> -> v end}
      true -> :unsupported
    end
  end

  # ClickHouse's plain `DateTime` (and `DateTime(timezone)`, whose wire
  # encoding is identical -- the parameter only affects display/parsing
  # timezone, not storage) is a little-endian `UInt32` Unix-epoch second
  # count (confirmed live against ClickHouse 24.8: `SELECT
  # toUInt32(now())` matches the raw bytes of a `DateTime` column holding
  # the same instant). There's no fractional-second component -- that's
  # `DateTime64(N)`, not handled here -- so this always decodes to a
  # whole-second `DateTime.t()` in `Etc/UTC` (the epoch itself is
  # timezone-agnostic; `Etc/UTC` is just the zone used to represent it as
  # an Elixir struct, matching how Ecto's built-in `:naive_datetime`/
  # `:utc_datetime` types expect a UTC `DateTime` to load from).
  defp decode_datetime(<<v::unsigned-little-32>>), do: DateTime.from_unix!(v, :second)

  defp decode_fixed_width(binary, num_rows, byte_size, unpack) do
    total = num_rows * byte_size

    case binary do
      <<data::binary-size(total), rest::binary>> ->
        values =
          for <<chunk::binary-size(byte_size) <- data>> do
            unpack.(chunk)
          end

        {:ok, values, rest}

      _ ->
        {:incomplete, binary}
    end
  end

  defp decode_strings(binary, 0, acc), do: {:ok, Enum.reverse(acc), binary}

  defp decode_strings(binary, remaining, acc) do
    case Varint.decode_string(binary) do
      {:ok, value, rest} -> decode_strings(rest, remaining - 1, [value | acc])
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  defp transpose(_column_data, 0), do: []

  defp transpose(column_data, num_rows) do
    for row_index <- 0..(num_rows - 1) do
      Enum.map(column_data, fn values -> Enum.at(values, row_index) end)
    end
  end
end
