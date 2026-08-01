defmodule ChDriver.Protocol.NativeBlock do
  @moduledoc """
  Decodes ClickHouse's "Native" block format — the columns and rows of a
  query result, once any compression envelope has been stripped away.

  This is internal to the driver's decoding pipeline. A block carries its
  column names, types, and row data; `decode_block/1` turns that into
  `%{columns: [{name, type}], rows: [[term]]}`.

  Only a pragmatic subset of ClickHouse's type system is supported — see
  `ChDriver.Types.Registry` for the scalar types and
  `ChDriver.Protocol.Block.Wrappers` for compound types like `Array`,
  `Map`, and `Nullable`. If you're adding support for a new ClickHouse
  type, `ARCHITECTURE.md` has the map of which module owns what.
  """

  alias ChDriver.Protocol.Block.Sparse
  alias ChDriver.Protocol.Block.Wrappers
  alias ChDriver.Protocol.Varint
  alias ChDriver.Types
  alias ChDriver.Types.Registry

  @doc """
  Decodes a Data or ProfileEvents packet body: the external table name,
  followed by a Native block.

  `compression` (`:none` (default) or `:lz4`) must match whatever was
  negotiated for this query — when `:lz4`, the block is decompressed
  before decoding.

  Returns `{:ok, %{table_name:, columns:, rows:}, rest}`,
  `{:incomplete, binary}`, or `{:error, reason}`.
  """
  @spec decode_data_packet(binary, ChDriver.Protocol.Block.Compressed.method()) ::
          {:ok, map, binary} | {:incomplete, binary} | {:error, term}
  def decode_data_packet(binary, compression \\ :none) do
    with {:ok, table_name, rest} <- Varint.decode_string(binary),
         {:ok, block, rest} <- decode_block_body(rest, compression) do
      {:ok, Map.put(block, :table_name, table_name), rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_block_body(binary, :none), do: decode_block(binary)

  defp decode_block_body(binary, :lz4) do
    case ChDriver.Protocol.Block.Compressed.decode(binary) do
      {:ok, decompressed, rest} ->
        with {:ok, block, <<>>} <- decode_block(decompressed) do
          {:ok, block, rest}
        else
          {:ok, _block, _extra} ->
            {:error, {:trailing_bytes_after_compressed_block, decompressed}}

          {:incomplete, _} ->
            {:error, {:short_compressed_block, decompressed}}

          {:error, reason} ->
            {:error, reason}
        end

      {:incomplete, _missing_byte_count} ->
        {:incomplete, binary}

      {:error, reason} ->
        {:error, reason}
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
  # majority of columns (plain/`DEFAULT` serialization) -- see
  # `ChDriver.Protocol.Block.Sparse`'s moduledoc for the byte-level
  # details of the case where it's 1.
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
    do: Sparse.decode_sparse(type, num_rows, binary)

  # Flat, single-pass dispatch: try each `ChDriver.Types` wrapper parser in
  # turn (via `Enum.find_value/2`) and call its matching
  # `ChDriver.Protocol.Block.Wrappers` decoder right in the same closure,
  # instead of first normalizing into a tagged tuple that a *second*,
  # separate `case` then has to stay in sync with by hand (that was the
  # original shape here, and the same footgun `ChDriver.Protocol.Block.Sparse`'s
  # `default_value/1` used to have -- see commit 26387d2). Falls back to
  # `decode_plain/3` (the `ChDriver.Types.Registry.column_codec/1` table)
  # once every wrapper parser has missed. `:error` (a truthy, non-`nil`
  # term) is mapped to `nil` so `Enum.find_value/2` -- which only treats
  # `nil`/`false` as "keep scanning" -- doesn't stop at the first parser
  # that simply didn't match. Extending this with a new wrapper type means
  # adding one more attempt to the list, nothing else -- there's no second
  # place that needs a matching clause.
  @doc false
  def decode_column_data(type, num_rows, binary) do
    wrapper_attempts = [
      fn t ->
        with {:ok, inner} <- Types.parse_nullable(t),
             do: Wrappers.decode_nullable(inner, num_rows, binary)
      end,
      fn t ->
        with {:ok, inner} <- Types.parse_array(t),
             do: Wrappers.decode_array(inner, num_rows, binary)
      end,
      fn t ->
        with {:ok, key_type, value_type} <- Types.parse_map(t),
             do: Wrappers.decode_map(key_type, value_type, num_rows, binary)
      end,
      fn t ->
        with {:ok, inner} <- Types.parse_low_cardinality(t),
             do: Wrappers.decode_low_cardinality(inner, num_rows, binary)
      end,
      fn t ->
        with {:ok, precision, scale} <- Types.parse_decimal(t),
             do: Wrappers.decode_decimal(precision, scale, num_rows, binary)
      end,
      fn t ->
        with {:ok, size} <- Types.parse_fixed_string(t),
             do: Registry.decode_fixed_width(binary, num_rows, size, & &1)
      end
    ]

    Enum.find_value(wrapper_attempts, fn attempt ->
      case attempt.(type) do
        :error -> nil
        result -> result
      end
    end) || decode_plain(type, num_rows, binary)
  end

  defp decode_plain(type, num_rows, binary) do
    case Registry.column_codec(type) do
      {:fixed, byte_size, unpack} ->
        Registry.decode_fixed_width(binary, num_rows, byte_size, unpack)

      :string ->
        Registry.decode_strings(binary, num_rows, [])

      :unsupported ->
        {:error, {:unsupported_type, type}}
    end
  end

  defp transpose(_column_data, 0), do: []

  defp transpose(column_data, num_rows) do
    for row_index <- 0..(num_rows - 1) do
      Enum.map(column_data, fn values -> Enum.at(values, row_index) end)
    end
  end
end
