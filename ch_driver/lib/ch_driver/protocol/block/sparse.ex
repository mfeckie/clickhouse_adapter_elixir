defmodule ChDriver.Protocol.Block.Sparse do
  @moduledoc """
  Decodes ClickHouse's "sparse" column serialization.

  ClickHouse automatically switches a MergeTree column to sparse storage
  once most of its values equal the type's default, whether or not anyone
  asked for it — so this driver needs to understand the format for any
  query against a real table, not just an opt-in feature. See
  `ARCHITECTURE.md` for the full wire format if you're modifying this.

  Only inner types with a known default value are supported; anything else
  surfaces as `{:error, {:unsupported_sparse_default, type}}`.
  """

  alias ChDriver.Protocol.NativeBlock
  alias ChDriver.Protocol.Varint
  alias ChDriver.Types

  # Bit 62 of a `SparseOffsets` varint (see moduledoc) -- `1 <<< 62`, chosen
  # by ClickHouse because its varints only ever carry values `< 2^63`, so
  # this bit can never collide with an actual group-size value.
  @end_of_granule_flag 0x4000000000000000

  @doc """
  Decodes a sparse-serialized column of `inner_type` with `num_rows` rows
  from the front of `binary`.

  Returns `{:ok, values, rest}`, `{:error, reason}`, or `{:incomplete, binary}`.
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
  Reads the `SparseOffsets` varint stream from the front of `binary`.

  Returns `{:ok, offsets, rest}` where `offsets` is the 0-indexed row
  position of every non-default value, in ascending order, or
  `{:incomplete, binary}`.
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
  #
  # Same two-step flat dispatch as
  # `ChDriver.Protocol.NativeBlock.classify_type/1` +
  # `decode_column_data/3`: try each `ChDriver.Types` wrapper parser in
  # turn (flat list, no nesting) via `Enum.find_value/2`, normalize
  # whichever one matches into a tagged tuple, then one flat `case` on
  # that tuple -- falling back to `scalar_default_value/1` when none of
  # the wrapper parsers match. Extending this with a new wrapper type
  # means adding one entry to `wrapper_parsers` and one `case` clause,
  # not another nesting level.
  defp default_value(type) do
    wrapper_parsers = [
      fn t ->
        case Types.parse_nullable(t) do
          {:ok, inner} -> {:nullable, inner}
          :error -> nil
        end
      end,
      fn t ->
        case Types.parse_array(t) do
          {:ok, inner} -> {:array, inner}
          :error -> nil
        end
      end,
      fn t ->
        case Types.parse_map(t) do
          {:ok, key_type, value_type} -> {:map, key_type, value_type}
          :error -> nil
        end
      end,
      fn t ->
        case Types.parse_low_cardinality(t) do
          {:ok, inner} -> {:low_cardinality, inner}
          :error -> nil
        end
      end,
      fn t ->
        case Types.parse_decimal(t) do
          {:ok, precision, scale} -> {:decimal, precision, scale}
          :error -> nil
        end
      end,
      fn t ->
        case Types.parse_fixed_string(t) do
          {:ok, size} -> {:fixed_string, size}
          :error -> nil
        end
      end
    ]

    case Enum.find_value(wrapper_parsers, fn parser -> parser.(type) end) do
      {:nullable, _inner} -> {:ok, nil}
      {:array, _inner} -> {:ok, []}
      {:map, _key_type, _value_type} -> {:ok, %{}}
      {:low_cardinality, inner_type} -> default_value(inner_type)
      {:decimal, _precision, scale} -> {:ok, Decimal.new(1, 0, -scale)}
      {:fixed_string, size} -> {:ok, :binary.copy(<<0>>, size)}
      nil -> scalar_default_value(type)
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
