defmodule ChDriver.Protocol.Varint do
  @moduledoc """
  LEB128-style unsigned varint encoding used throughout ClickHouse's native
  protocol for packet-type discriminants, lengths, revisions, and other
  small-to-medium unsigned integers.

  Each byte contributes 7 bits of the value, low-order bits first. The high
  bit of a byte is a continuation flag: 1 means "more bytes follow", 0 means
  "this is the last byte".

  Also provides ClickHouse's length-prefixed string encoding: a varint byte
  length followed by that many raw bytes (no encoding assumptions, no
  trailing NUL).
  """

  @doc """
  Encodes a non-negative integer as a varint, returning a binary.
  """
  @spec encode(non_neg_integer) :: binary
  def encode(value) when is_integer(value) and value >= 0 do
    do_encode(value, <<>>)
  end

  defp do_encode(value, acc) when value < 0x80 do
    <<acc::binary, value::8>>
  end

  defp do_encode(value, acc) do
    byte = Bitwise.bor(Bitwise.band(value, 0x7F), 0x80)
    do_encode(Bitwise.bsr(value, 7), <<acc::binary, byte::8>>)
  end

  @doc """
  Decodes a varint from the front of `binary`.

  Returns `{:ok, value, rest}` on success, or `{:incomplete, binary}` if the
  buffer doesn't yet contain a complete varint (no byte with the
  continuation bit unset).
  """
  @spec decode(binary) :: {:ok, non_neg_integer, binary} | {:incomplete, binary}
  def decode(binary) when is_binary(binary) do
    do_decode(binary, 0, 0)
  end

  defp do_decode(<<byte::8, rest::binary>>, shift, acc) do
    acc = Bitwise.bor(acc, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {:ok, acc, rest}
    else
      do_decode(rest, shift + 7, acc)
    end
  end

  defp do_decode(<<>>, _shift, _acc) do
    {:incomplete, <<>>}
  end

  @doc """
  Encodes a binary as a ClickHouse length-prefixed string: a varint byte
  length followed by the raw bytes.
  """
  @spec encode_string(binary) :: iodata
  def encode_string(binary) when is_binary(binary) do
    [encode(byte_size(binary)), binary]
  end

  @doc """
  Decodes a ClickHouse length-prefixed string from the front of `binary`.

  Returns `{:ok, string, rest}` on success, or `{:incomplete, binary}` if
  the buffer doesn't yet contain the full length prefix and/or string
  bytes.
  """
  @spec decode_string(binary) :: {:ok, binary, binary} | {:incomplete, binary}
  def decode_string(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, length, rest} ->
        if byte_size(rest) >= length do
          <<string::binary-size(length), remainder::binary>> = rest
          {:ok, string, remainder}
        else
          {:incomplete, binary}
        end

      {:incomplete, _} ->
        {:incomplete, binary}
    end
  end
end
