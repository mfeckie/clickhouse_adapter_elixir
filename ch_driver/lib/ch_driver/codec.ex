defmodule ChDriver.Codec do
  @moduledoc """
  LZ4 compression and CityHash checksums, backed by a Rust NIF.

  These are the low-level primitives ClickHouse's wire compression is built
  on: `lz4_compress/1` and `lz4_decompress/2` work with raw LZ4 blocks (not
  the LZ4 Frame format), and `cityhash128/1` computes the checksum
  ClickHouse uses to verify each compressed block.

  You won't normally call this module directly — `ChDriver.Protocol.Block.Compressed`
  builds the full block envelope on top of it. It's public because the
  primitives are useful on their own if you need raw LZ4/CityHash outside
  the driver.
  """

  alias ChDriver.Codec.Native

  @doc "Compresses `data` using raw LZ4 block compression (no frame header)."
  @spec lz4_compress(iodata) :: binary
  def lz4_compress(data), do: Native.lz4_compress(IO.iodata_to_binary(data))

  @doc """
  Decompresses a raw LZ4 block.

  `uncompressed_size` must be known ahead of time — the raw LZ4 block
  format has no length prefix of its own, so the caller has to supply it
  (ClickHouse carries it in the block header).
  """
  @spec lz4_decompress(iodata, non_neg_integer) :: {:ok, binary} | {:error, String.t()}
  def lz4_decompress(data, uncompressed_size) do
    Native.lz4_decompress(IO.iodata_to_binary(data), uncompressed_size)
  end

  @doc """
  Computes the 128-bit CityHash v1.0.2 checksum of `data`, returned as a
  16-byte binary already in ClickHouse's on-wire byte order.
  """
  @spec cityhash128(iodata) :: <<_::128>>
  def cityhash128(data), do: Native.cityhash128(IO.iodata_to_binary(data))
end
