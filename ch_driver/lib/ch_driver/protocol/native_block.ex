defmodule ChDriver.Protocol.NativeBlock do
  @moduledoc """
  Decodes ClickHouse's plaintext "Native" block format -- the payload of a
  Data (or wire-identical ProfileEvents) packet once compression is
  disabled (this driver always negotiates `compression: 0` in
  `ChDriver.Protocol.encode_query/2`, so blocks are never wrapped in
  `ChNative.Block`'s compressed envelope).

  Format (matches `Formats/NativeReader.cpp`, protocol revision 54469):

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

  This module owns block/packet framing and the top-level
  `decode_column_data/3` type dispatch only. The rest of the type system
  is split out by concern, matching how a new type or wrapper should be
  added:

    * `ChDriver.Types` -- parses a column *type string* (e.g.
      `"Nullable(String)"`) into its component parts. Add a new
      `parse_*/1` clause here for a new wrapper syntax.
    * `ChDriver.Types.Registry` -- the scalar/fixed-width codec table
      (`column_codec/1`) and the primitive wire readers
      (`decode_fixed_width/4`, `decode_strings/3`) it hands out. Add a
      new scalar ClickHouse type here.
    * `ChDriver.Protocol.Block.Wrappers` -- decoders for `Nullable(T)`,
      `Array(T)`, `Map(K, V)`, `LowCardinality(T)`, and `Decimal(P, S)`.
      Add a new wrapper/compound decoder here, alongside a dispatch clause
      in this module's `decode_column_data/3` and a parser in
      `ChDriver.Types`.
    * `ChDriver.Protocol.Block.Sparse` -- decodes MergeTree's "sparse"
      column serialization (see its moduledoc for the full wire format).

  `decode_column_data/3` is this module's extension point for new
  wrapper/compound types: add a clause here that pattern-matches/parses
  the type string via `ChDriver.Types`, plus a `decode_*` function in
  `ChDriver.Protocol.Block.Wrappers`. Note that `decode_column_data/3`
  recurses through `ChDriver.Protocol.Block.Wrappers` and
  `ChDriver.Protocol.Block.Sparse` (that's what makes
  `Array(Nullable(String))` work for free), so those modules call back
  into this one across the module boundary -- deliberately fine in
  Elixir, since none of the calls are macros.
  """

  alias ChDriver.Protocol.Block.Sparse
  alias ChDriver.Protocol.Block.Wrappers
  alias ChDriver.Protocol.Varint
  alias ChDriver.Types
  alias ChDriver.Types.Registry

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

  # Top-level type dispatch. Compound/wrapper types that need more than a
  # single fixed-width-or-string codec (Nullable, Array, Map,
  # LowCardinality, Decimal) get their own clause here (parsed via
  # `ChDriver.Types`) and their own decoder function in
  # `ChDriver.Protocol.Block.Wrappers` -- everything else falls through to
  # the plain `ChDriver.Types.Registry.column_codec/1` table. This is the
  # extension point for new wrapper types: add a clause here that
  # pattern-matches/parses the type string, plus a `decode_*` function
  # alongside `ChDriver.Protocol.Block.Wrappers.decode_nullable/3`.
  @doc false
  def decode_column_data(type, num_rows, binary) do
    case Types.parse_nullable(type) do
      {:ok, inner_type} ->
        Wrappers.decode_nullable(inner_type, num_rows, binary)

      :error ->
        case Types.parse_array(type) do
          {:ok, inner_type} ->
            Wrappers.decode_array(inner_type, num_rows, binary)

          :error ->
            case Types.parse_map(type) do
              {:ok, key_type, value_type} ->
                Wrappers.decode_map(key_type, value_type, num_rows, binary)

              :error ->
                case Types.parse_low_cardinality(type) do
                  {:ok, inner_type} ->
                    Wrappers.decode_low_cardinality(inner_type, num_rows, binary)

                  :error ->
                    case Types.parse_decimal(type) do
                      {:ok, precision, scale} ->
                        Wrappers.decode_decimal(precision, scale, num_rows, binary)

                      :error ->
                        case Types.parse_fixed_string(type) do
                          {:ok, size} ->
                            Registry.decode_fixed_width(binary, num_rows, size, & &1)

                          :error ->
                            case Registry.column_codec(type) do
                              {:fixed, byte_size, unpack} ->
                                Registry.decode_fixed_width(binary, num_rows, byte_size, unpack)

                              :string ->
                                Registry.decode_strings(binary, num_rows, [])

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

  defp transpose(_column_data, 0), do: []

  defp transpose(column_data, num_rows) do
    for row_index <- 0..(num_rows - 1) do
      Enum.map(column_data, fn values -> Enum.at(values, row_index) end)
    end
  end
end
