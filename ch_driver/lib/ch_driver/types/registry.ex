defmodule ChDriver.Types.Registry do
  @moduledoc """
  The scalar/fixed-width type codec table (`column_codec/1`) plus the
  primitive wire readers it hands out: `decode_fixed_width/4` (fixed-width
  binary chunks, one per row, each run through a per-type unpack function)
  and `decode_strings/3` (ClickHouse's length-prefixed `String` encoding).

  A pragmatic subset of ClickHouse's type system: fixed-width integer and
  float types (by exact name), `String`, and a handful of common types
  (`DateTime`, `Enum8`/`Enum16`, `UUID`, `IPv4`, `IPv6`) that show up in
  ClickHouse's own ProfileEvents packets sent alongside every query
  result, or that this driver otherwise supports end to end. Not a general
  type system -- see `ChDriver.Protocol.NativeBlock`'s moduledoc for the
  full list of what this driver supports and where each piece lives.
  Adding a new scalar ClickHouse type is a one-line addition to
  `column_codec/1` here.

  `UUID`'s wire format: 16 bytes, laid out as the UUID's standard 16
  text-representation bytes with *each 8-byte half byte-reversed
  independently* -- i.e. NOT the naive byte order, and NOT a swap of the
  two halves either. Concretely, for UUID
  `61f0c404-5cb3-11e7-907b-a6006ad3dba0` (standard bytes
  `61 f0 c4 04 5c b3 11 e7 90 7b a6 00 6a d3 db a0`), ClickHouse's raw
  in-memory/wire bytes are
  `e7 11 b3 5c 04 c4 f0 61 a0 db d3 6a 00 a6 7b 90` -- reversing bytes
  0..7 and, separately, bytes 8..15 of the wire form recovers the
  standard form byte-for-byte.

  `IPv4`'s wire format (`hex(reinterpretAsFixedString(
  toIPv4('192.168.1.1')))` -> `0101A8C0`, i.e. the same little-endian
  `UInt32` encoding as every other ClickHouse integer type --
  `192.168.1.1` is `0xC0A80101` as a plain big-endian-read integer, and
  the wire bytes `01 01 A8 C0` are exactly that value's little-endian byte
  order): decoded to the dotted-quad text form (matching this module's
  `UUID` decode-to-text convention) by re-reading the same 4 bytes as a
  big-endian `UInt32` and splitting into octets.

  `IPv6`'s wire format (`hex(reinterpretAsFixedString(
  toIPv6('2001:db8::1')))` -> `20010DB8000000000000000000000001`, and
  `hex(reinterpretAsFixedString(toIPv6('::ffff:192.168.1.1')))` ->
  `00000000000000000000FFFFC0A80101`): a plain 16-byte value in standard
  network byte order -- i.e. byte-for-byte identical to the address's
  normal text-form byte layout, with **no** reversal of any kind (unlike
  `UUID`, whose wire form independently byte-reverses each 8-byte half).
  Decoded to the standard colon-hex text form via `:inet.ntoa/1` on the 8
  big-endian 16-bit groups.

  `FixedString(N)`'s wire format (`hex(toFixedString('ab', 5))` ->
  `6162000000`; matches `DataTypeFixedString.cpp`'s
  `deserializeBinaryBulk`): exactly `N` raw bytes per row, right-padded
  with `0x00` up to `N` if the value is shorter -- unlike `String`, there
  is no length-prefix varint at all, and unlike `String`'s own
  null-termination-free encoding, the padding bytes are real wire
  content. ClickHouse does **not** trim the padding back out on
  `SELECT` -- the padded value is the column's actual value -- so this
  decodes to the raw `N`-byte binary verbatim, trailing NULs included,
  via `decode_fixed_width/4` with an identity unpack function (see
  `ChDriver.Types.parse_fixed_string/1`'s call site in
  `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3`).
  """

  alias ChDriver.Protocol.Varint

  @doc """
  Looks up the fixed-width/string codec for a scalar ClickHouse type name.
  Returns `{:fixed, byte_size, unpack_fun}`, `:string`, or `:unsupported`.
  """
  def column_codec("UInt8"), do: {:fixed, 1, fn <<v::unsigned-little-8>> -> v end}
  def column_codec("UInt16"), do: {:fixed, 2, fn <<v::unsigned-little-16>> -> v end}
  def column_codec("UInt32"), do: {:fixed, 4, fn <<v::unsigned-little-32>> -> v end}
  def column_codec("UInt64"), do: {:fixed, 8, fn <<v::unsigned-little-64>> -> v end}
  def column_codec("Int8"), do: {:fixed, 1, fn <<v::signed-little-8>> -> v end}
  def column_codec("Int16"), do: {:fixed, 2, fn <<v::signed-little-16>> -> v end}
  def column_codec("Int32"), do: {:fixed, 4, fn <<v::signed-little-32>> -> v end}
  def column_codec("Int64"), do: {:fixed, 8, fn <<v::signed-little-64>> -> v end}
  def column_codec("Float32"), do: {:fixed, 4, fn <<v::float-little-32>> -> v end}
  def column_codec("Float64"), do: {:fixed, 8, fn <<v::float-little-64>> -> v end}
  def column_codec("DateTime"), do: {:fixed, 4, &decode_datetime/1}
  def column_codec("String"), do: :string
  def column_codec("UUID"), do: {:fixed, 16, &decode_uuid/1}
  def column_codec("IPv4"), do: {:fixed, 4, &decode_ipv4/1}
  def column_codec("IPv6"), do: {:fixed, 16, &decode_ipv6/1}

  def column_codec("DateTime(" <> _), do: {:fixed, 4, &decode_datetime/1}
  def column_codec("Enum8(" <> _), do: {:fixed, 1, fn <<v::signed-little-8>> -> v end}
  def column_codec("Enum16(" <> _), do: {:fixed, 2, fn <<v::signed-little-16>> -> v end}
  def column_codec(_), do: :unsupported

  # ClickHouse's plain `DateTime` (and `DateTime(timezone)`, whose wire
  # encoding is identical -- the parameter only affects display/parsing
  # timezone, not storage) is a little-endian `UInt32` Unix-epoch second
  # count (`SELECT toUInt32(now())` matches the raw bytes of a `DateTime`
  # column holding the same instant). There's no fractional-second
  # component -- that's `DateTime64(N)`, not handled here -- so this
  # always decodes to a
  # whole-second `DateTime.t()` in `Etc/UTC` (the epoch itself is
  # timezone-agnostic; `Etc/UTC` is just the zone used to represent it as
  # an Elixir struct, matching how Ecto's built-in `:naive_datetime`/
  # `:utc_datetime` types expect a UTC `DateTime` to load from).
  defp decode_datetime(<<v::unsigned-little-32>>), do: DateTime.from_unix!(v, :second)

  defp decode_uuid(<<hi::binary-size(8), lo::binary-size(8)>>) do
    hex = Base.encode16(reverse_bytes(hi) <> reverse_bytes(lo), case: :lower)
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e
  end

  defp reverse_bytes(binary) do
    binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end

  defp decode_ipv4(<<v::unsigned-little-32>>) do
    <<a::8, b::8, c::8, d::8>> = <<v::unsigned-big-32>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp decode_ipv6(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()
  end

  @doc """
  Reads `num_rows` fixed-width `byte_size`-byte chunks from `binary`,
  running each through `unpack` (e.g. `fn <<v::unsigned-little-32>> -> v
  end`). Returns `{:ok, values, rest}` or `{:incomplete, binary}` if fewer
  than `num_rows * byte_size` bytes are available.
  """
  def decode_fixed_width(binary, num_rows, byte_size, unpack) do
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

  @doc """
  Reads `remaining` ClickHouse `String` values (varint length prefix +
  bytes) from `binary`. Returns `{:ok, values, rest}` or `{:incomplete,
  binary}`.
  """
  def decode_strings(binary, 0, acc), do: {:ok, Enum.reverse(acc), binary}

  def decode_strings(binary, remaining, acc) do
    case Varint.decode_string(binary) do
      {:ok, value, rest} -> decode_strings(rest, remaining - 1, [value | acc])
      {:incomplete, _} -> {:incomplete, binary}
    end
  end
end
