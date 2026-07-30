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

  # Parses ClickHouse's `Nullable(T)` wrapper syntax, returning the inner
  # type string. Not a general parenthesis-balancer -- just strips the
  # leading `Nullable(` and trailing `)` -- but that's sufficient even for
  # a parameterized inner type like `Nullable(DateTime(3))`, since the
  # outer `)` is always the last byte of the whole type string.
  defp parse_nullable("Nullable(" <> rest) when byte_size(rest) > 0 do
    case String.split_at(rest, byte_size(rest) - 1) do
      {inner, ")"} -> {:ok, inner}
      _ -> :error
    end
  end

  defp parse_nullable(_type), do: :error

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
