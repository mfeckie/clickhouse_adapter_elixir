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
    * `FixedString(N)` (clickhouse_adapter_elixir-8a2.21), decoded to a raw
      `N`-byte Elixir binary, null-padding included verbatim.
    * `IPv4` (clickhouse_adapter_elixir-8a2.21), decoded to its dotted-quad
      text form (matching the `UUID`/text-form convention already used by
      this module -- see `decode_ipv4/1`).
    * `IPv6` (clickhouse_adapter_elixir-8a2.21), decoded to its standard
      colon-hex text form via `:inet.ntoa/1` (see `decode_ipv6/1`).
    * `Map(K, V)` (clickhouse_adapter_elixir-8a2.21) for any scalar `K`/`V`
      this module already knows how to decode, decoded to an Elixir `map()`
      per row (see `decode_map/3` for the confirmed-live wire format).

  Deliberately still deferred: `Tuple(...)` in its own right (only
  supported today as `Map(K, V)`'s implicit internal representation, not as
  a directly-selectable column type -- see `decode_map/3`'s moduledoc for
  why generalizing it is more work than it looks).

  ## Sparse serialization

  ClickHouse automatically stores a MergeTree column using "sparse"
  serialization once enough of its values equal the type's default (see
  `ratio_of_defaults_for_sparse_serialization`, default `0.9`), regardless
  of whether the user asked for it. On the wire this shows up as the
  `has_custom_serialization` byte (see above) being `1`, followed by one
  more `UInt8` "serialization kind" byte (confirmed against ClickHouse's
  `ISerialization::Kind` enum in `ISerialization.h` and
  `SerializationInfo::deserializeFromKindsBinary` in
  `SerializationInfo.cpp`): `0` = `DEFAULT` (never actually sent, since
  `hasCustomSerialization()` is false whenever `kind == DEFAULT` --
  `NativeWriter.cpp` only writes the kind byte at all when
  `has_custom_serialization` is 1) and `1` = `SPARSE`, the only other kind
  that exists as of ClickHouse 24.8. Any other byte value is rejected with a
  clear error rather than guessed at, since it would mean a newer
  ClickHouse serialization kind this driver doesn't understand.

  Sparse's own column-data encoding (confirmed against
  `SerializationSparse.cpp`'s `serializeOffsets`/`deserializeOffsets`/
  `deserializeBinaryBulkWithMultipleStreams`, and cross-checked live against
  a real MergeTree column ClickHouse chose to store as `Sparse`) is two
  back-to-back substreams -- *not* a null-map-style parallel array like
  `Nullable`:

    * `SparseOffsets`: a sequence of `UInt64` varints, each a "group size"
      -- the number of consecutive default-valued rows since the last
      non-default row (or since the start of the block) -- immediately
      followed by exactly one non-default row (whose actual value lives in
      the `SparseElements` substream below, densely packed, one entry per
      group). The final varint in the sequence has bit 62
      (`END_OF_GRANULE_FLAG` = `1 <<< 62`, chosen because ClickHouse's
      varints only ever carry values `< 2^63`) set, and its low bits are the
      count of trailing default rows with no following value -- this is how
      the reader knows to stop without needing to know the offset-stream's
      byte length up front. E.g. for 10 rows with non-default values at
      (0-indexed) rows 2 and 5, the stream is the three varints `2`, `2`,
      `4 | END_OF_GRANULE_FLAG` (2 defaults, 1 value, 2 defaults, 1 value, 4
      trailing defaults, done) -- there is always at least one flagged
      varint, even for an all-default or zero-row block.
    * `SparseElements`: exactly as many densely-packed values of the inner
      type as there were non-default rows above, decoded via that type's
      own `decode_column_data/3` (recursively, same pattern as
      `Nullable`/`Array`).

  Decoding reconstructs the full `num_rows`-length column by walking the
  offsets and interleaving the decoded non-default values at their
  positions with the inner type's own default value (`0`/`0.0`/`""`/`nil`/
  `[]`/`%{}`/etc, per `default_value/1`) everywhere else. Only inner types
  `default_value/1` knows how to produce a default for are supported;
  anything else surfaces as `{:error, {:unsupported_sparse_default, type}}`
  rather than guessing.
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
         {:ok, sparse?, rest} <- decode_serialization_kind(has_custom, type, rest),
         {:ok, values, rest} <- decode_maybe_sparse(sparse?, type, num_rows, rest) do
      do_decode_columns(rest, remaining - 1, num_rows, [{name, type} | columns_acc], [
        values | data_acc
      ])
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:has_custom, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  # The `has_custom_serialization` UInt8 flag is 0 for the overwhelming
  # majority of columns (plain/`DEFAULT` serialization) -- see the
  # moduledoc's "Sparse serialization" section for the byte-level details of
  # the case where it's 1.
  defp decode_serialization_kind(0, _type, rest), do: {:ok, false, rest}

  defp decode_serialization_kind(_other, type, <<kind::8, rest::binary>>) do
    case kind do
      0 -> {:ok, false, rest}
      1 -> {:ok, true, rest}
      other -> {:error, {:unsupported_custom_serialization, type, other}}
    end
  end

  defp decode_serialization_kind(_other, _type, rest), do: {:incomplete, rest}

  defp decode_maybe_sparse(false, type, num_rows, binary),
    do: decode_column_data(type, num_rows, binary)

  defp decode_maybe_sparse(true, type, num_rows, binary),
    do: decode_sparse(type, num_rows, binary)

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
            case parse_map(type) do
              {:ok, key_type, value_type} ->
                decode_map(key_type, value_type, num_rows, binary)

              :error ->
                case parse_low_cardinality(type) do
                  {:ok, inner_type} ->
                    decode_low_cardinality(inner_type, num_rows, binary)

                  :error ->
                    case parse_decimal(type) do
                      {:ok, precision, scale} ->
                        decode_decimal(precision, scale, num_rows, binary)

                      :error ->
                        case parse_fixed_string(type) do
                          {:ok, size} ->
                            decode_fixed_width(binary, num_rows, size, & &1)

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

  # Parses ClickHouse's `Map(K, V)` wrapper syntax, returning `{:ok, key_type,
  # value_type}`. Splits on the top-level comma only (tracking paren depth so
  # e.g. `Map(String, Decimal(10, 2))` isn't split on the inner comma).
  defp parse_map(type) do
    with {:ok, inner} <- strip_wrapper(type, "Map("),
         [key_type, value_type] <- split_top_level_comma(inner) do
      {:ok, String.trim(key_type), String.trim(value_type)}
    else
      _ -> :error
    end
  end

  defp split_top_level_comma(inner) do
    inner
    |> String.to_charlist()
    |> do_split_top_level_comma(0, [], [])
  end

  defp do_split_top_level_comma([], 0, current, acc) do
    Enum.reverse([current |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split_top_level_comma([], _depth, _current, _acc), do: :error

  defp do_split_top_level_comma([?( | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth + 1, [?( | current], acc)
  end

  defp do_split_top_level_comma([?) | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth - 1, [?) | current], acc)
  end

  defp do_split_top_level_comma([?, | rest], 0, current, acc) do
    do_split_top_level_comma(rest, 0, [], [current |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split_top_level_comma([char | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth, [char | current], acc)
  end

  # Parses ClickHouse's `FixedString(N)` type, returning `{:ok, n}`.
  defp parse_fixed_string("FixedString(" <> rest) do
    case Regex.run(~r/^(\d+)\)$/, rest) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  defp parse_fixed_string(_type), do: :error

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

  # `Map(K, V)`'s wire format (confirmed live against ClickHouse 24.8, byte-
  # for-byte, against a real `Map(String, UInt32)` column with both empty
  # and populated map values): ClickHouse's own documentation and
  # `DataTypeMap.cpp` state that `Map(K, V)` is implemented internally as
  # `Array(Tuple(K, V))`, and its wire encoding follows that exactly --
  # `num_rows`-long cumulative little-endian `UInt64` offsets (identical to
  # `Array(T)`'s own offsets -- `offsets[i]` is the end index, exclusive, of
  # row i's entries in the flattened key/value columns below), immediately
  # followed by the *whole flattened key column* (`total_elements` values of
  # `K`, decoded via `K`'s own `decode_column_data/3`) and then the *whole
  # flattened value column* (`total_elements` values of `V`) -- i.e. a
  # `Tuple(K, V)` column is serialized as one sub-stream per tuple field,
  # back to back, not as interleaved (key, value) pairs. Confirmed live by
  # decoding a captured `Map(String, UInt32)` payload by hand: interpreting
  # the bytes as "all offsets, then all keys, then all values" round-trips
  # `{'a':1,'b':2}` correctly, while an interleaved-pairs reading does not
  # (it misaligns the `String` length-prefix bytes against unrelated
  # `UInt32` value bytes).
  defp decode_map(key_type, value_type, num_rows, binary) do
    with {:ok, offsets, rest} <-
           decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_keys, rest} <- decode_column_data(key_type, total_elements, rest),
         {:ok, flat_values, rest} <- decode_column_data(value_type, total_elements, rest) do
      entries = Enum.zip(flat_keys, flat_values)
      rows = split_by_offsets(entries, offsets)
      {:ok, Enum.map(rows, &Map.new/1), rest}
    end
  end

  # Bit 62 of a `SparseOffsets` varint (see moduledoc) -- `1 <<< 62`, chosen
  # by ClickHouse because its varints only ever carry values `< 2^63`, so
  # this bit can never collide with an actual group-size value.
  @end_of_granule_flag 0x4000000000000000

  # Sparse's wire format (see the moduledoc's "Sparse serialization"
  # section for the full byte-level explanation, confirmed against
  # `SerializationSparse.cpp` and live against a real ClickHouse `Sparse`
  # column): a `SparseOffsets` varint stream giving the position of every
  # non-default row, followed by a `SparseElements` stream of exactly that
  # many densely-packed values of `inner_type`, decoded via
  # `decode_column_data/3` like any other wrapper type here.
  defp decode_sparse(inner_type, num_rows, binary) do
    with {:ok, offsets, rest} <- decode_sparse_offsets(binary),
         {:ok, default} <- default_value(inner_type),
         {:ok, values, rest} <- decode_column_data(inner_type, length(offsets), rest) do
      {:ok, expand_sparse(offsets, values, num_rows, default), rest}
    else
      :error -> {:error, {:unsupported_sparse_default, inner_type}}
      {:error, reason} -> {:error, reason}
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  # Reads `SparseOffsets`: repeated `(group_size, value)` pairs -- where
  # `group_size` is the count of default rows immediately preceding that
  # value's row -- terminated by one final flagged varint (bit 62 set)
  # giving the count of trailing default rows with no following value.
  # Returns the 0-indexed row position of every non-default value, in
  # ascending order (matching the order their values appear in the
  # following `SparseElements` stream).
  defp decode_sparse_offsets(binary), do: do_decode_sparse_offsets(binary, 0, [])

  defp do_decode_sparse_offsets(binary, total_rows, acc) do
    case Varint.decode(binary) do
      {:ok, raw, rest} ->
        end_of_granule? = Bitwise.band(raw, @end_of_granule_flag) != 0
        group_size = if end_of_granule?, do: raw - @end_of_granule_flag, else: raw

        if end_of_granule? do
          {:ok, Enum.reverse(acc), rest}
        else
          offset = total_rows + group_size
          do_decode_sparse_offsets(rest, offset + 1, [offset | acc])
        end

      {:incomplete, _} ->
        {:incomplete, binary}
    end
  end

  # Rebuilds the full `num_rows`-length column from `offsets` (ascending
  # 0-indexed positions of non-default rows) and `values` (the
  # correspondingly-ordered decoded non-default values), filling every
  # other position with `default`.
  defp expand_sparse(offsets, values, num_rows, default),
    do: do_expand_sparse(offsets, values, 0, num_rows, default, [])

  defp do_expand_sparse(_offsets, _values, row, num_rows, _default, acc) when row == num_rows,
    do: Enum.reverse(acc)

  defp do_expand_sparse([offset | offsets], [value | values], row, num_rows, default, acc)
       when offset == row do
    do_expand_sparse(offsets, values, row + 1, num_rows, default, [value | acc])
  end

  defp do_expand_sparse(offsets, values, row, num_rows, default, acc) do
    do_expand_sparse(offsets, values, row + 1, num_rows, default, [default | acc])
  end

  # The default (zero) value for every type `decode_column_data/3` knows
  # how to decode -- used to fill in the rows `decode_sparse/3` doesn't get
  # an explicit value for. Mirrors `decode_column_data/3`'s own dispatch
  # structure: wrapper types delegate to their inner type (except
  # `Nullable`/`Array`/`Map`, whose default is a fixed shape regardless of
  # the inner/key/value type), and everything else is a fixed per-type
  # constant. Returns `{:ok, default}` or `:error` for any type without a
  # known default (surfaced by `decode_sparse/3` as a clear
  # `:unsupported_sparse_default` error rather than guessed at).
  defp default_value(type) do
    case parse_nullable(type) do
      {:ok, _inner} ->
        {:ok, nil}

      :error ->
        case parse_array(type) do
          {:ok, _inner} ->
            {:ok, []}

          :error ->
            case parse_map(type) do
              {:ok, _key_type, _value_type} ->
                {:ok, %{}}

              :error ->
                case parse_low_cardinality(type) do
                  {:ok, inner_type} ->
                    default_value(inner_type)

                  :error ->
                    case parse_decimal(type) do
                      {:ok, _precision, scale} ->
                        {:ok, Decimal.new(1, 0, -scale)}

                      :error ->
                        case parse_fixed_string(type) do
                          {:ok, size} -> {:ok, :binary.copy(<<0>>, size)}
                          :error -> scalar_default_value(type)
                        end
                    end
                end
            end
        end
    end
  end

  @integer_types ~w(UInt8 UInt16 UInt32 UInt64 Int8 Int16 Int32 Int64)
  @float_types ~w(Float32 Float64)

  defp scalar_default_value(type) when type in @integer_types, do: {:ok, 0}
  defp scalar_default_value(type) when type in @float_types, do: {:ok, 0.0}
  defp scalar_default_value("String"), do: {:ok, ""}
  defp scalar_default_value("UUID"), do: {:ok, "00000000-0000-0000-0000-000000000000"}
  defp scalar_default_value("IPv4"), do: {:ok, "0.0.0.0"}
  defp scalar_default_value("IPv6"), do: {:ok, "::"}
  defp scalar_default_value("DateTime"), do: {:ok, DateTime.from_unix!(0, :second)}

  defp scalar_default_value(type) do
    cond do
      String.starts_with?(type, "DateTime(") -> {:ok, DateTime.from_unix!(0, :second)}
      String.starts_with?(type, "Enum8(") -> {:ok, 0}
      String.starts_with?(type, "Enum16(") -> {:ok, 0}
      true -> :error
    end
  end

  # `FixedString(N)`'s wire format (confirmed live against ClickHouse 24.8
  # via `hex(toFixedString('ab', 5))` -> `6162000000`, and cross-referenced
  # with `DataTypeFixedString.cpp`'s `deserializeBinaryBulk`): exactly `N`
  # raw bytes per row, right-padded with `0x00` up to `N` if the value is
  # shorter -- unlike `String`, there is no length-prefix varint at all, and
  # unlike `String`'s own null-termination-free encoding, the padding bytes
  # are real wire content. Confirmed live (via `length(f)` on a real
  # `FixedString(5)` column holding `'ab'`) that ClickHouse does **not**
  # trim the padding back out on `SELECT` -- the padded value is the
  # column's actual value -- so this decodes to the raw `N`-byte binary
  # verbatim, trailing NULs included, via the generic `decode_fixed_width/4`
  # with an identity unpack function (see `parse_fixed_string/1`'s call
  # site).

  # `IPv4`'s wire format (confirmed live: `hex(reinterpretAsFixedString(
  # toIPv4('192.168.1.1')))` -> `0101A8C0`, i.e. the same little-endian
  # `UInt32` encoding as every other ClickHouse integer type -- `192.168.1.1`
  # is `0xC0A80101` as a plain big-endian-read integer, and the wire bytes
  # `01 01 A8 C0` are exactly that value's little-endian byte order):
  # decoded to the dotted-quad text form (matching this module's existing
  # `UUID` decode-to-text convention) by re-reading the same 4 bytes as a
  # big-endian `UInt32` and splitting into octets.
  defp decode_ipv4(<<v::unsigned-little-32>>) do
    <<a::8, b::8, c::8, d::8>> = <<v::unsigned-big-32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  # `IPv6`'s wire format (confirmed live: `hex(reinterpretAsFixedString(
  # toIPv6('2001:db8::1')))` -> `20010DB8000000000000000000000001`, and
  # `hex(reinterpretAsFixedString(toIPv6('::ffff:192.168.1.1')))` ->
  # `00000000000000000000FFFFC0A80101`): a plain 16-byte value in standard
  # network byte order -- i.e. byte-for-byte identical to the address's
  # normal text-form byte layout, with **no** reversal of any kind (unlike
  # `UUID`, whose wire form independently byte-reverses each 8-byte half --
  # see `decode_uuid/1`). Decoded to the standard colon-hex text form via
  # `:inet.ntoa/1` on the 8 big-endian 16-bit groups.
  defp decode_ipv6(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()
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
  defp column_codec("IPv4"), do: {:fixed, 4, &decode_ipv4/1}
  defp column_codec("IPv6"), do: {:fixed, 16, &decode_ipv6/1}

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
