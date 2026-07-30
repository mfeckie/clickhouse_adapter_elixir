defmodule ChCodec do
  @moduledoc """
  LZ4 block compression and CityHash v1.0.3 checksums for ClickHouse's
  native protocol block framing.

  ClickHouse wraps every block (compressed or not) in a fixed envelope:

      [16 bytes] CityHash128 checksum (over everything below)
      [1 byte]   compression method marker
      [4 bytes]  compressed size, little-endian (header + payload)
      [4 bytes]  uncompressed size, little-endian
      [...]      payload

  This module provides the two primitives needed to build and verify that
  envelope: `lz4_compress/1` and `lz4_decompress/2` operate on the raw LZ4
  block format (not the LZ4 Frame format), and `cityhash128/1` returns the
  16-byte checksum already packed in ClickHouse's on-wire byte order.
  """

  alias ChCodec.Native

  @doc "Compresses `data` using raw LZ4 block compression (no frame header)."
  @spec lz4_compress(iodata) :: binary
  def lz4_compress(data), do: Native.lz4_compress(IO.iodata_to_binary(data))

  @doc """
  Decompresses a raw LZ4 block. `uncompressed_size` must be known ahead of
  time (ClickHouse carries it in the block header) since the raw block
  format has no length prefix of its own.
  """
  @spec lz4_decompress(iodata, non_neg_integer) :: {:ok, binary} | {:error, String.t()}
  def lz4_decompress(data, uncompressed_size) do
    Native.lz4_decompress(IO.iodata_to_binary(data), uncompressed_size)
  end

  @doc """
  Computes the 128-bit CityHash v1.0.3 checksum of `data`, returned as a
  16-byte binary already in ClickHouse's on-wire byte order.
  """
  @spec cityhash128(iodata) :: <<_::128>>
  def cityhash128(data), do: Native.cityhash128(IO.iodata_to_binary(data))
end
