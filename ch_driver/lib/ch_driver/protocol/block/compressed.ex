defmodule ChDriver.Protocol.Block.Compressed do
  @moduledoc """
  Encodes and decodes ClickHouse's compressed block envelope: a checksum
  and a method marker wrapped around a block's bytes, LZ4-compressed or
  plain.

  Multiple blocks are concatenated back-to-back with no extra framing —
  call `decode/1` repeatedly, threading the returned `rest` through, until
  the buffer is exhausted.

  This is what backs the `:compression` option on `ChDriver.start_link/1`
  and `ChDriver.query/4` — you won't normally call `encode/2`/`decode/1`
  directly. Built on `ChDriver.Codec`'s LZ4/CityHash primitives.
  """

  @checksum_size 16
  @header_size 9
  @prefix_size @checksum_size + @header_size

  @method_none 0x02
  @method_lz4 0x82

  @type method :: :none | :lz4

  @doc """
  Encodes `iodata` into a single compressed block envelope using `method`
  (defaults to `:lz4`).
  """
  @spec encode(iodata, method) :: binary
  def encode(iodata, method \\ :lz4)

  def encode(iodata, :lz4) do
    payload = IO.iodata_to_binary(iodata)
    uncompressed_size = byte_size(payload)
    compressed_payload = ChDriver.Codec.lz4_compress(payload)
    build(@method_lz4, compressed_payload, uncompressed_size)
  end

  def encode(iodata, :none) do
    payload = IO.iodata_to_binary(iodata)
    build(@method_none, payload, byte_size(payload))
  end

  defp build(method_byte, stored_payload, uncompressed_size) do
    compressed_size = @header_size + byte_size(stored_payload)

    header = <<
      method_byte::8,
      compressed_size::little-32,
      uncompressed_size::little-32
    >>

    checksum = ChDriver.Codec.cityhash128([header, stored_payload])

    [checksum, header, stored_payload]
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes a single block envelope from the front of `binary`.

  Returns:
    * `{:ok, decompressed, rest}` on success, where `rest` is any
      unconsumed bytes following this block (e.g. the start of the next one).
    * `{:incomplete, missing_byte_count}` if not enough bytes are buffered
      yet to make progress. `missing_byte_count` is how many more bytes are
      needed before calling `decode/1` again is worth doing.
    * `{:error, reason}` if the checksum doesn't match or the method byte
      is unrecognized.
  """
  @spec decode(binary) ::
          {:ok, binary, binary}
          | {:incomplete, non_neg_integer}
          | {:error, term}
  def decode(binary) when byte_size(binary) < @prefix_size do
    {:incomplete, @prefix_size - byte_size(binary)}
  end

  def decode(binary) do
    <<
      checksum::binary-size(@checksum_size),
      method_byte::8,
      compressed_size::little-32,
      uncompressed_size::little-32,
      rest_after_header::binary
    >> = binary

    payload_size = compressed_size - @header_size

    if payload_size < 0 do
      {:error, {:invalid_compressed_size, compressed_size}}
    else
      total_needed = @checksum_size + compressed_size

      if byte_size(binary) < total_needed do
        {:incomplete, total_needed - byte_size(binary)}
      else
        <<payload::binary-size(payload_size), rest::binary>> = rest_after_header

        header = <<
          method_byte::8,
          compressed_size::little-32,
          uncompressed_size::little-32
        >>

        expected_checksum = ChDriver.Codec.cityhash128([header, payload])

        if checksum == expected_checksum do
          decode_payload(method_byte, payload, uncompressed_size, rest)
        else
          {:error, :checksum_mismatch}
        end
      end
    end
  end

  defp decode_payload(@method_none, payload, uncompressed_size, rest) do
    if byte_size(payload) == uncompressed_size do
      {:ok, payload, rest}
    else
      {:error, {:size_mismatch, expected: uncompressed_size, got: byte_size(payload)}}
    end
  end

  defp decode_payload(@method_lz4, payload, uncompressed_size, rest) do
    case ChDriver.Codec.lz4_decompress(payload, uncompressed_size) do
      {:ok, decompressed} -> {:ok, decompressed, rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(method_byte, _payload, _uncompressed_size, _rest) do
    {:error, {:unsupported_method, method_byte}}
  end
end
