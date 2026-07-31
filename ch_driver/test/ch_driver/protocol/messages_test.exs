defmodule ChDriver.Protocol.MessagesTest do
  use ExUnit.Case, async: true

  alias ChDriver.Protocol.Messages

  describe "encode_query/2 compression byte, in isolation from a live server" do
    test "omitting :compression is byte-for-byte identical to explicitly passing :compression: :none" do
      omitted = Messages.encode_query("SELECT 1") |> IO.iodata_to_binary()

      explicit_none =
        Messages.encode_query("SELECT 1", compression: :none) |> IO.iodata_to_binary()

      assert omitted == explicit_none
    end

    test "the encoded compression varint is 0 (disabled) by default" do
      encoded = Messages.encode_query("SELECT 1") |> IO.iodata_to_binary()

      # Field order: packet type, query_id string, ClientInfo, two empty
      # settings/secret strings, query stage varint, THEN the compression
      # varint -- rather than hand-parse the whole ClientInfo blob, just
      # confirm the byte pattern for query-stage-complete (2) immediately
      # followed by compression-disabled (0) appears, and that requesting
      # :lz4 changes only that one byte (2 followed by 1) versus the
      # default encoding, with everything else identical.
      compressed = Messages.encode_query("SELECT 1", compression: :lz4) |> IO.iodata_to_binary()

      assert byte_size(encoded) == byte_size(compressed)
      assert encoded != compressed

      # Exactly one byte differs between the two encodings: the
      # compression varint. Confirms :compression only touches that single
      # field and nothing else about the Query packet layout.
      diffs =
        for {a, b} <- Enum.zip(:binary.bin_to_list(encoded), :binary.bin_to_list(compressed)),
            a != b,
            do: {a, b}

      assert diffs == [{0, 1}]
    end
  end

  describe "encode_empty_data_packet/1" do
    test "omitting :compression is byte-for-byte identical to explicitly passing :none" do
      omitted = Messages.encode_empty_data_packet() |> IO.iodata_to_binary()
      explicit_none = Messages.encode_empty_data_packet(:none) |> IO.iodata_to_binary()

      assert omitted == explicit_none
    end

    test ":lz4 wraps the block body in a ChDriver.Protocol.Block.Compressed envelope, changing its size" do
      plain = Messages.encode_empty_data_packet(:none) |> IO.iodata_to_binary()
      compressed = Messages.encode_empty_data_packet(:lz4) |> IO.iodata_to_binary()

      assert byte_size(compressed) > byte_size(plain)

      # packet type (2) + external table name (empty string -> 1 byte, 0)
      # are always plain and identical between the two.
      assert binary_part(plain, 0, 2) == binary_part(compressed, 0, 2)

      # Immediately after that 2-byte plain prefix, the compressed version
      # carries a ChDriver.Protocol.Block.Compressed envelope: 16-byte checksum then method
      # byte 0x82 (LZ4).
      <<_prefix::binary-size(2), _checksum::binary-size(16), method::8, _rest::binary>> =
        compressed

      assert method == 0x82
    end
  end
end
