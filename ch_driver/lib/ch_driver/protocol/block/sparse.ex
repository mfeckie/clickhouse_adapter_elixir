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
  # Flat, single-pass dispatch: try each `ChDriver.Types` wrapper parser in
  # turn (via `Enum.find_value/2`) and compute its default value right in
  # the same closure, instead of nesting one `case` inside another for
  # each wrapper type. Unlike `ChDriver.Protocol.NativeBlock.classify_type/1`
  # (whose tagged tuple has to be handed off to a *different* function,
  # `decode_column_data/3`, so it's normalized into an intermediate tuple
  # first), nothing here needs that hand-off -- each parser's match and the
  # value it produces never separate, so there's no tag name that has to
  # stay in sync across two lists. `:error` (a truthy, non-`nil` term) is
  # mapped to `nil` so `Enum.find_value/2` -- which only treats `nil`/
  # `false` as "keep scanning" -- doesn't stop at the first parser that
  # simply didn't match. Falls back to `scalar_default_value/1` once every
  # wrapper parser has missed. Extending this with a new wrapper type means
  # adding one more attempt to the list, nothing else. (The list is built
  # fresh on each call rather than hoisted to a module attribute: one
  # attempt recurses into `default_value/1` itself, and a module attribute
  # is evaluated before the function it would be referencing exists.)
  defp default_value(type) do
    wrapper_attempts = [
      fn t -> with {:ok, _inner} <- Types.parse_nullable(t), do: {:ok, nil} end,
      fn t -> with {:ok, _inner} <- Types.parse_array(t), do: {:ok, []} end,
      fn t -> with {:ok, _key_type, _value_type} <- Types.parse_map(t), do: {:ok, %{}} end,
      fn t ->
        with {:ok, inner_type} <- Types.parse_low_cardinality(t), do: default_value(inner_type)
      end,
      fn t ->
        with {:ok, _precision, scale} <- Types.parse_decimal(t),
             do: {:ok, Decimal.new(1, 0, -scale)}
      end,
      fn t ->
        with {:ok, size} <- Types.parse_fixed_string(t), do: {:ok, :binary.copy(<<0>>, size)}
      end
    ]

    Enum.find_value(wrapper_attempts, fn attempt ->
      case attempt.(type) do
        :error -> nil
        result -> result
      end
    end) || scalar_default_value(type)
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
