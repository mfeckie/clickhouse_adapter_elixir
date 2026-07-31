defmodule ChDriver.Protocol.Block.Sparse do
  @moduledoc """
  ## Sparse serialization

  ClickHouse automatically stores a MergeTree column using "sparse"
  serialization once enough of its values equal the type's default (see
  `ratio_of_defaults_for_sparse_serialization`, default `0.9`), regardless
  of whether the user asked for it. On the wire this shows up as the
  `has_custom_serialization` byte (see
  `ChDriver.Protocol.NativeBlock.decode_serialization_kind/3`) being `1`,
  followed by one more `UInt8` "serialization kind" byte (per ClickHouse's
  `ISerialization::Kind` enum in `ISerialization.h` and
  `SerializationInfo::deserializeFromKindsBinary` in
  `SerializationInfo.cpp`): `0` = `DEFAULT` (never actually sent, since
  `hasCustomSerialization()` is false whenever `kind == DEFAULT` --
  `NativeWriter.cpp` only writes the kind byte at all when
  `has_custom_serialization` is 1) and `1` = `SPARSE`, the only other kind
  that exists as of ClickHouse 24.8. Any other byte value is rejected with a
  clear error rather than guessed at, since it would mean a newer
  ClickHouse serialization kind this driver doesn't understand.

  Sparse's own column-data encoding (matches
  `SerializationSparse.cpp`'s `serializeOffsets`/`deserializeOffsets`/
  `deserializeBinaryBulkWithMultipleStreams`) is two back-to-back
  substreams -- *not* a null-map-style parallel array like `Nullable`:

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
      `Nullable`/`Array` in `ChDriver.Protocol.Block.Wrappers`).

  Decoding reconstructs the full `num_rows`-length column by walking the
  offsets and interleaving the decoded non-default values at their
  positions with the inner type's own default value (`0`/`0.0`/`""`/`nil`/
  `[]`/`%{}`/etc, per `default_value/1`) everywhere else. Only inner types
  `default_value/1` knows how to produce a default for are supported;
  anything else surfaces as `{:error, {:unsupported_sparse_default, type}}`
  rather than guessing.
  """

  alias ChDriver.Protocol.NativeBlock
  alias ChDriver.Protocol.Varint
  alias ChDriver.Types

  # Bit 62 of a `SparseOffsets` varint (see moduledoc) -- `1 <<< 62`, chosen
  # by ClickHouse because its varints only ever carry values `< 2^63`, so
  # this bit can never collide with an actual group-size value.
  @end_of_granule_flag 0x4000000000000000

  @doc """
  Sparse's wire format (see this module's moduledoc for the full
  byte-level explanation; matches `SerializationSparse.cpp`): a
  `SparseOffsets` varint stream giving the position of every non-default
  row, followed by a `SparseElements` stream of exactly that many
  densely-packed values of `inner_type`, decoded via
  `ChDriver.Protocol.NativeBlock.decode_column_data/3` like any other
  wrapper type.
  """
  def decode_sparse(inner_type, num_rows, binary) do
    with {:ok, offsets, rest} <- decode_sparse_offsets(binary),
         {:ok, default} <- default_value(inner_type),
         {:ok, values, rest} <- NativeBlock.decode_column_data(inner_type, length(offsets), rest) do
      {:ok, expand_sparse(offsets, values, num_rows, default), rest}
    else
      :error -> {:error, {:unsupported_sparse_default, inner_type}}
      {:error, reason} -> {:error, reason}
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  @doc """
  Reads `SparseOffsets`: repeated `(group_size, value)` pairs -- where
  `group_size` is the count of default rows immediately preceding that
  value's row -- terminated by one final flagged varint (bit 62 set)
  giving the count of trailing default rows with no following value.
  Returns the 0-indexed row position of every non-default value, in
  ascending order (matching the order their values appear in the
  following `SparseElements` stream).
  """
  def decode_sparse_offsets(binary), do: do_decode_sparse_offsets(binary, 0, [])

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

  @doc """
  Rebuilds the full `num_rows`-length column from `offsets` (ascending
  0-indexed positions of non-default rows) and `values` (the
  correspondingly-ordered decoded non-default values), filling every
  other position with `default`.
  """
  def expand_sparse(offsets, values, num_rows, default),
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
    case Types.parse_nullable(type) do
      {:ok, _inner} ->
        {:ok, nil}

      :error ->
        case Types.parse_array(type) do
          {:ok, _inner} ->
            {:ok, []}

          :error ->
            case Types.parse_map(type) do
              {:ok, _key_type, _value_type} ->
                {:ok, %{}}

              :error ->
                case Types.parse_low_cardinality(type) do
                  {:ok, inner_type} ->
                    default_value(inner_type)

                  :error ->
                    case Types.parse_decimal(type) do
                      {:ok, _precision, scale} ->
                        {:ok, Decimal.new(1, 0, -scale)}

                      :error ->
                        case Types.parse_fixed_string(type) do
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

  defp scalar_default_value("DateTime(" <> _), do: {:ok, DateTime.from_unix!(0, :second)}
  defp scalar_default_value("Enum8(" <> _), do: {:ok, 0}
  defp scalar_default_value("Enum16(" <> _), do: {:ok, 0}
  defp scalar_default_value(_), do: :error
end
