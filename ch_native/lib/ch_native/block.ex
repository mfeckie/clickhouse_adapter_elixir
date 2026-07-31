defmodule ChNative.Block do
  @moduledoc """
  Encodes and decodes ClickHouse native-protocol compressed block envelopes.

  Wire format (see ClickHouse's `CompressionInfo.h` / `CompressedReadBufferBase.cpp`):

      [16 bytes] CityHash128 checksum, over everything below
      [1 byte]   compression method marker (0x02 = NONE, 0x82 = LZ4, 0x90 = ZSTD)
      [4 bytes]  compressed_size, little-endian -- covers the 9-byte
                 method+sizes header itself, plus the (possibly compressed) payload
      [4 bytes]  uncompressed_size, little-endian
      [...]      payload (compressed unless method is NONE)

  Multiple blocks are simply concatenated back-to-back with no additional
  framing -- callers should call `decode/1` repeatedly, threading the
  returned `rest` through, until the buffer is exhausted.

  ## Wired into ChDriver as opt-in compression

  Both `encode/2` and `decode/1` are called from `ch_driver`, gated behind
  its `:compression` option (`:none` by default, `:lz4` to opt in):
  `ChDriver.Protocol.Messages.encode_query/2` negotiates compression with the
  server via the Query packet's compression flag, `encode_empty_data_packet/1`
  routes the outbound external-table block through `encode/2` when enabled,
  and `ChDriver.Protocol.decode_packet/2` ->
  `ChDriver.Protocol.NativeBlock.decode_data_packet/2` routes inbound
  Data/ProfileEvents blocks through `decode/1` the same way. See
  `ChDriver.Connection`'s `:compression` option docs for the client-facing
  API and `ChDriver.Protocol.Messages.encode_query/2`'s moduledoc for the
  wire-level negotiation details.
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
    compressed_payload = ChCodec.lz4_compress(payload)
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

    checksum = ChCodec.cityhash128([header, stored_payload])

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

        expected_checksum = ChCodec.cityhash128([header, payload])

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
    case ChCodec.lz4_decompress(payload, uncompressed_size) do
      {:ok, decompressed} -> {:ok, decompressed, rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(method_byte, _payload, _uncompressed_size, _rest) do
    {:error, {:unsupported_method, method_byte}}
  end
end
