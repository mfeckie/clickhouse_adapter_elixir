defmodule ChDriver.Protocol.Block.Wrappers do
  @moduledoc """
  Decoders for ClickHouse's wrapper and compound column types: `Nullable(T)`,
  `Array(T)`, `Map(K, V)`, `LowCardinality(T)`, `Variant(T1, ..., Tn)`, and
  `Decimal(P, S)`.

  Dispatched from `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3`,
  which these functions recurse back into for their inner type(s) — that's
  what lets deeply nested types like `Array(Nullable(String))` or
  `Map(String, Array(UInt32))` decode correctly without any special-casing.

  `Map(K, V)` values decode to plain Elixir maps; `Array(T)` and
  `LowCardinality(T)` decode to lists; `Nullable(T)` decodes to the inner
  value or `nil`; `Variant(...)` decodes to whichever alternative each row
  selected (or `nil`); `Decimal(P, S)` decodes to a `Decimal.t()`. See
  `ARCHITECTURE.md` for the wire-level byte layouts.

  Each decoder takes and returns the hoisted serialization-prefix list —
  see `ChDriver.Protocol.NativeBlock`'s moduledoc for why prefixes are read
  up front rather than inline.
  """

  alias ChDriver.Protocol.NativeBlock
  alias ChDriver.Types
  alias ChDriver.Types.Registry

  @doc false
  def decode_nullable(inner_type, num_rows, binary, prefixes) do
    with {:ok, null_map, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 1, fn <<v::8>> -> v end),
         {:ok, values, rest, prefixes} <-
           NativeBlock.decode_column_data(inner_type, num_rows, rest, prefixes) do
      combined =
        null_map
        |> Enum.zip(values)
        |> Enum.map(fn
          {1, _value} -> nil
          {0, value} -> value
        end)

      {:ok, combined, rest, prefixes}
    end
  end

  @doc false
  # A tuple is stored element-wise: all `num_rows` values of element 1, then
  # all of element 2, and so on. Decode each element as its own full column,
  # then zip them back into per-row Elixir tuples.
  def decode_tuple(element_types, num_rows, binary, prefixes) do
    result =
      Enum.reduce_while(element_types, {:ok, [], binary, prefixes}, fn element_type,
                                                                       {:ok, acc, rest, prefixes} ->
        case NativeBlock.decode_column_data(element_type, num_rows, rest, prefixes) do
          {:ok, values, rest, prefixes} -> {:cont, {:ok, [values | acc], rest, prefixes}}
          other -> {:halt, other}
        end
      end)

    with {:ok, reversed_columns, rest, prefixes} <- result do
      rows =
        reversed_columns
        |> Enum.reverse()
        |> Enum.zip_with(&List.to_tuple/1)

      {:ok, rows, rest, prefixes}
    end
  end

  @doc false
  def decode_array(inner_type, num_rows, binary, prefixes) do
    with {:ok, offsets, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_values, rest, prefixes} <-
           NativeBlock.decode_column_data(inner_type, total_elements, rest, prefixes) do
      {:ok, split_by_offsets(flat_values, offsets), rest, prefixes}
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
  def decode_map(key_type, value_type, num_rows, binary, prefixes) do
    with {:ok, offsets, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 8, fn <<v::unsigned-little-64>> -> v end),
         total_elements = List.last(offsets, 0),
         {:ok, flat_keys, rest, prefixes} <-
           NativeBlock.decode_column_data(key_type, total_elements, rest, prefixes),
         {:ok, flat_values, rest, prefixes} <-
           NativeBlock.decode_column_data(value_type, total_elements, rest, prefixes) do
      entries = Enum.zip(flat_keys, flat_values)
      rows = split_by_offsets(entries, offsets)
      {:ok, Enum.map(rows, &Map.new/1), rest, prefixes}
    end
  end

  # The discriminator byte a `Variant` row carries when it holds no value
  # at all (ClickHouse's `NULL_DISCRIMINATOR`); any other value is a
  # 0-based index into the alternatives, in type-name order.
  @null_discriminator 255

  @doc """
  Decodes a `Variant(T1, ..., Tn)` column: one discriminator byte per row
  (the 0-based index of the alternative that row holds, in the type name's
  order, or `255` for no value), followed by one contiguous sub-column per
  alternative, in alternative order, holding *only* the rows that selected
  it.

  An alternative no row selected contributes zero bytes, so the
  discriminators have to be counted before any sub-column can be read —
  which is exactly why this can't be a streaming per-row decode.

  `Variant`'s own 8-byte discriminator-mode prefix was already consumed by
  `ChDriver.Protocol.NativeBlock.decode_prefixes/2`, so it's popped off
  `prefixes` here rather than read from `binary`.
  """
  def decode_variant(alternatives, num_rows, binary, prefixes) do
    {_mode, prefixes} = pop_prefix(prefixes)

    with {:ok, discriminators, rest} <-
           Registry.decode_fixed_width(binary, num_rows, 1, fn <<v::8>> -> v end),
         {:ok, sub_columns, rest, prefixes} <-
           decode_variant_sub_columns(alternatives, discriminators, rest, prefixes) do
      {:ok, interleave_variant(discriminators, sub_columns), rest, prefixes}
    end
  end

  # Decodes each alternative's sub-column, sized by how many rows chose
  # that alternative, returning them keyed by discriminator index.
  defp decode_variant_sub_columns(alternatives, discriminators, binary, prefixes) do
    counts = Enum.frequencies(discriminators)

    alternatives
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, binary, prefixes}, fn {alternative, index},
                                                          {:ok, acc, rest, prefixes} ->
      case NativeBlock.decode_column_data(
             alternative,
             Map.get(counts, index, 0),
             rest,
             prefixes
           ) do
        {:ok, values, rest, prefixes} ->
          {:cont, {:ok, Map.put(acc, index, values), rest, prefixes}}

        other ->
          {:halt, other}
      end
    end)
  end

  # Walks the discriminators in row order, taking the next value from
  # whichever alternative's sub-column that row pointed at.
  defp interleave_variant(discriminators, sub_columns) do
    {values, _remaining} =
      Enum.map_reduce(discriminators, sub_columns, fn
        @null_discriminator, remaining ->
          {nil, remaining}

        discriminator, remaining ->
          [value | rest] = Map.fetch!(remaining, discriminator)
          {value, Map.put(remaining, discriminator, rest)}
      end)

    values
  end

  defp pop_prefix([prefix | rest]), do: {prefix, rest}
  defp pop_prefix([]), do: {nil, []}

  @doc false
  def decode_low_cardinality(_inner_type, 0, binary, prefixes), do: {:ok, [], binary, prefixes}

  def decode_low_cardinality(inner_type, _num_rows, binary, prefixes) do
    # The 8-byte dictionary key version was already consumed as a hoisted
    # prefix (see `ChDriver.Protocol.NativeBlock`'s moduledoc), so decoding
    # starts at the per-block index type/flags word.
    {_key_version, prefixes} = pop_prefix(prefixes)

    # A LowCardinality(Nullable(T)) dictionary has no null map. ClickHouse
    # reserves index 0 as the NULL sentinel and stores a default-valued
    # element there instead, so the dictionary is read as plain T and index
    # 0 maps to nil. Note this is positional: an actual "" or 0 value gets
    # its own (non-zero) dictionary slot, so it must not be confused with
    # the sentinel that happens to hold the same bytes.
    {dictionary_type, nullable?} =
      case Types.parse_nullable(inner_type) do
        {:ok, unwrapped} -> {unwrapped, true}
        :error -> {inner_type, false}
      end

    with {:ok, [index_type_and_flags], rest} <-
           Registry.decode_fixed_width(binary, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, [dictionary_size], rest} <-
           Registry.decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         {:ok, dictionary, rest, prefixes} <-
           NativeBlock.decode_column_data(dictionary_type, dictionary_size, rest, prefixes),
         {:ok, [index_count], rest} <-
           Registry.decode_fixed_width(rest, 1, 8, fn <<v::unsigned-little-64>> -> v end),
         index_byte_size = index_byte_size(index_type_and_flags),
         {:ok, indexes, rest} <-
           Registry.decode_fixed_width(rest, index_count, index_byte_size, &decode_unsigned_le/1) do
      dictionary_tuple = List.to_tuple(dictionary)

      values =
        Enum.map(indexes, fn
          0 when nullable? -> nil
          index -> elem(dictionary_tuple, index)
        end)

      {:ok, values, rest, prefixes}
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
