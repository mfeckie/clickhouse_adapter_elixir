defmodule ChDriver.Protocol.Block.Wrappers do
  @moduledoc """
  Decoders for ClickHouse's wrapper and compound column types: `Nullable(T)`,
  `Array(T)`, `Map(K, V)`, `LowCardinality(T)`, and `Decimal(P, S)`.

  Dispatched from `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3`,
  which these functions recurse back into for their inner type(s) — that's
  what lets deeply nested types like `Array(Nullable(String))` or
  `Map(String, Array(UInt32))` decode correctly without any special-casing.

  `Map(K, V)` values decode to plain Elixir maps; `Array(T)` and
  `LowCardinality(T)` decode to lists; `Nullable(T)` decodes to the inner
  value or `nil`; `Decimal(P, S)` decodes to a `Decimal.t()`. See
  `ARCHITECTURE.md` for the wire-level byte layouts.
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
