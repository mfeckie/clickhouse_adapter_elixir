defmodule ChDriver.Protocol.Block.CompressedTest do
  use ExUnit.Case, async: true

  alias ChDriver.Protocol.Block.Compressed, as: Block

  describe "round-trip" do
    test "via lz4" do
      payload = String.duplicate("hello clickhouse ", 100)
      encoded = Block.encode(payload, :lz4)

      assert {:ok, decoded, ""} = Block.decode(encoded)
      assert decoded == payload
    end

    test "via none" do
      payload = "small payload that should not be compressed"
      encoded = Block.encode(payload, :none)

      assert {:ok, decoded, ""} = Block.decode(encoded)
      assert decoded == payload
    end

    test "default method is lz4" do
      payload = "default method payload"
      encoded = Block.encode(payload)

      assert {:ok, decoded, ""} = Block.decode(encoded)
      assert decoded == payload
    end

    test "empty payload round-trips via lz4" do
      encoded = Block.encode("", :lz4)
      assert {:ok, "", ""} = Block.decode(encoded)
    end

    test "empty payload round-trips via none" do
      encoded = Block.encode("", :none)
      assert {:ok, "", ""} = Block.decode(encoded)
    end
  end

  describe "checksum verification" do
    test "detects a corrupted byte in the payload" do
      payload = "some payload data that is long enough to matter"
      encoded = Block.encode(payload, :lz4)

      corrupted = corrupt_byte(encoded, byte_size(encoded) - 1)

      assert {:error, _reason} = Block.decode(corrupted)
    end

    test "detects a corrupted byte in the header" do
      payload = "another payload"
      encoded = Block.encode(payload, :none)

      # flip a bit in the uncompressed_size field (byte 21, within the header)
      corrupted = corrupt_byte(encoded, 21)

      assert {:error, _reason} = Block.decode(corrupted)
    end

    test "detects a corrupted checksum byte" do
      payload = "yet another payload"
      encoded = Block.encode(payload, :none)

      corrupted = corrupt_byte(encoded, 0)

      assert {:error, _reason} = Block.decode(corrupted)
    end
  end

  describe "incomplete buffers" do
    test "fewer than 25 bytes reports incomplete with the remaining prefix count" do
      encoded = Block.encode("some data", :none)
      truncated = binary_part(encoded, 0, 10)

      assert {:incomplete, missing} = Block.decode(truncated)
      assert missing == 25 - 10
    end

    test "fewer than compressed_size bytes reports incomplete" do
      payload = String.duplicate("x", 200)
      encoded = Block.encode(payload, :lz4)

      # keep the full 25-byte prefix, but truncate the payload
      truncated = binary_part(encoded, 0, 30)

      assert {:incomplete, missing} = Block.decode(truncated)
      assert missing == byte_size(encoded) - 30
    end
  end

  describe "multi-block decoding" do
    test "decodes two concatenated blocks back-to-back" do
      payload1 = "first block payload"
      payload2 = "second block payload, a bit longer than the first one"

      encoded1 = Block.encode(payload1, :lz4)
      encoded2 = Block.encode(payload2, :none)

      stream = encoded1 <> encoded2

      assert {:ok, decoded1, rest} = Block.decode(stream)
      assert decoded1 == payload1

      assert {:ok, decoded2, ""} = Block.decode(rest)
      assert decoded2 == payload2
    end
  end

  describe "real ClickHouse fixtures" do
    # Raw bytes of real server-sent LZ4 compressed block envelopes, captured
    # from a ClickHouse 24.8 server over the native TCP protocol (port 9000)
    # straight off the socket before any decoding.
    #
    # `SELECT number FROM system.numbers LIMIT 5` produces three Data packets:
    # an empty header block (columns only, 0 rows), a block carrying the 5
    # result rows (5x UInt64 values), and an empty trailing block.
    @numbers_header_block Base.decode16!(
                            "c0a010ad4a7136515da9b8898edcde74822300000018000000f009010002ffffffff" <>
                              "000100066e756d6265720655496e743634",
                            case: :mixed
                          )

    @numbers_data_block Base.decode16!(
                          "4c3a86a4487f21fb3db44e20df7ed65d823b00000040000000f30a010002ffffffff" <>
                            "000105066e756d6265720655496e743634000100130108001302080013030800" <>
                            "800400000000000000",
                          case: :mixed
                        )

    @numbers_trailing_block Base.decode16!(
                              "a783ac6cd55c7a7cb5ac46bddb86e21482140000000a000000a0010002ffffffff000000",
                              case: :mixed
                            )

    # `SELECT number, number * 2 AS doubled, toString(number) AS s FROM
    # system.numbers LIMIT 3` -- multiple columns of different types
    # (UInt64, UInt64, String) in one block, captured the same way.
    @multi_column_header_block Base.decode16!(
                                 "94a09e7c394b59c863a1e41be0ddc010823700000030000000f311010002ffffffff" <>
                                   "000300066e756d6265720655496e74363407646f75626c65640f0090017306537472696e67",
                                 case: :mixed
                               )

    @multi_column_data_block Base.decode16!(
                               "05bfe9ebb7845c8dd2e4214c24cf6853825100000066000000f30a010002ffffffff" <>
                                 "000303066e756d6265720655496e74363400010013010800130208008b07646f75626c" <>
                                 "65642700041f0013042700f000017306537472696e67013001310132",
                               case: :mixed
                             )

    test "decodes a real empty header block (0 rows, single UInt64 column)" do
      assert {:ok, decoded, ""} = Block.decode(@numbers_header_block)

      assert decoded ==
               <<1, 0, 2, 255, 255, 255, 255, 0, 1, 0, 6, "number", 6, "UInt64">>
    end

    test "decodes a real block that actually carries row data" do
      assert {:ok, decoded, ""} = Block.decode(@numbers_data_block)

      assert byte_size(decoded) == 64

      assert decoded ==
               <<1, 0, 2, 255, 255, 255, 255, 0, 1, 5, 6, "number", 6, "UInt64">> <>
                 <<0::little-64, 1::little-64, 2::little-64, 3::little-64, 4::little-64>>
    end

    test "decodes the real empty trailing block sent after the data block" do
      assert {:ok, decoded, ""} = Block.decode(@numbers_trailing_block)
      assert decoded == <<1, 0, 2, 255, 255, 255, 255, 0, 0, 0>>
    end

    test "decodes a real multi-column header block" do
      assert {:ok, decoded, ""} = Block.decode(@multi_column_header_block)

      assert decoded ==
               <<1, 0, 2, 255, 255, 255, 255, 0, 3, 0, 6, "number", 6, "UInt64", 7, "doubled", 6,
                 "UInt64", 1, "s", 6, "String">>
    end

    test "decodes a real multi-column, multi-type block with row data" do
      assert {:ok, decoded, ""} = Block.decode(@multi_column_data_block)

      assert decoded ==
               <<1, 0, 2, 255, 255, 255, 255, 0, 3, 3, 6, "number", 6, "UInt64">> <>
                 <<0::little-64, 1::little-64, 2::little-64>> <>
                 <<7, "doubled", 6, "UInt64">> <>
                 <<0::little-64, 2::little-64, 4::little-64>> <>
                 <<1, "s", 6, "String", 1, "0", 1, "1", 1, "2">>
    end

    test "back-to-back real blocks from the same response decode via threaded rest" do
      stream = @numbers_header_block <> @numbers_data_block <> @numbers_trailing_block

      assert {:ok, header, rest} = Block.decode(stream)
      assert byte_size(header) == 24

      assert {:ok, data, rest2} = Block.decode(rest)
      assert byte_size(data) == 64

      assert {:ok, trailing, ""} = Block.decode(rest2)
      assert byte_size(trailing) == 10
    end

    test "rejects a real captured block if a payload byte is corrupted" do
      corrupted = corrupt_byte(@numbers_data_block, byte_size(@numbers_data_block) - 5)
      assert {:error, _reason} = Block.decode(corrupted)
    end
  end

  describe "partial TCP reads (real captured bytes split across two reads)" do
    # A DBConnection driver reading off a TCP socket will frequently see a
    # block's bytes arrive split across multiple `:gen_tcp` reads. This uses
    # real captured bytes (not synthetic binaries) to exercise the
    # `{:incomplete, n}` contract against a real server's byte layout.
    @full Base.decode16!(
            "4c3a86a4487f21fb3db44e20df7ed65d823b00000040000000f30a010002ffffffff" <>
              "000105066e756d6265720655496e743634000100130108001302080013030800" <>
              "800400000000000000",
            case: :mixed
          )

    test "fewer than the 25-byte prefix reports incomplete, then a second read completes it" do
      first_read = binary_part(@full, 0, 12)

      assert {:incomplete, missing} = Block.decode(first_read)
      assert missing == 25 - 12

      # second read delivers the rest of the socket buffer
      buffered = @full

      assert {:ok, decoded, ""} = Block.decode(buffered)
      assert byte_size(decoded) == 64
    end

    test "a full prefix but truncated payload reports incomplete, then completes on the next read" do
      first_read = binary_part(@full, 0, 40)

      assert {:incomplete, missing} = Block.decode(first_read)
      assert missing == byte_size(@full) - 40

      assert {:ok, decoded, ""} = Block.decode(@full)
      assert byte_size(decoded) == 64
    end

    test "simulated split-read across two gen_tcp chunks matches decoding the whole buffer" do
      {first_chunk, second_chunk} =
        {binary_part(@full, 0, 20), binary_part(@full, 20, byte_size(@full) - 20)}

      # first chunk alone: not enough
      assert {:incomplete, _} = Block.decode(first_chunk)

      # driver appends the second chunk to its buffer and retries
      reassembled = first_chunk <> second_chunk
      assert reassembled == @full

      assert {:ok, decoded, ""} = Block.decode(reassembled)
      assert byte_size(decoded) == 64
    end
  end

  describe "edge cases" do
    test "single-byte payload round-trips via lz4" do
      encoded = Block.encode("x", :lz4)
      assert {:ok, "x", ""} = Block.decode(encoded)
    end

    test "payloads shorter than LZ4's minimum match length (0..3 bytes) round-trip via lz4" do
      for size <- 0..3 do
        payload = :binary.copy(<<?a>>, size)
        encoded = Block.encode(payload, :lz4)
        assert {:ok, ^payload, ""} = Block.decode(encoded)
      end
    end

    test "a payload straddling typical small block-size boundaries round-trips via lz4" do
      for size <- [63, 64, 65, 255, 256, 257, 4095, 4096, 4097] do
        payload = :binary.copy(<<?z>>, size)
        encoded = Block.encode(payload, :lz4)
        assert {:ok, ^payload, ""} = Block.decode(encoded)
      end
    end

    test "property: random binaries of varying sizes round-trip via both methods" do
      for _ <- 1..50 do
        size = :rand.uniform(2000) - 1
        payload = :crypto.strong_rand_bytes(size)

        assert {:ok, ^payload, ""} = Block.decode(Block.encode(payload, :lz4))
        assert {:ok, ^payload, ""} = Block.decode(Block.encode(payload, :none))
      end
    end

    test "decode returns an error for an unrecognized method byte" do
      payload = "some payload"
      header = <<0xFF::8, 9 + byte_size(payload)::little-32, byte_size(payload)::little-32>>
      checksum = ChDriver.Codec.cityhash128([header, payload])
      binary = checksum <> header <> payload

      assert {:error, {:unsupported_method, 0xFF}} = Block.decode(binary)
    end

    test "decode rejects a compressed_size smaller than the header itself" do
      # Hand-craft a header claiming compressed_size == 3 (< the 9-byte
      # header size), which should be rejected before any checksum work.
      header = <<0x02::8, 3::little-32, 0::little-32>>
      checksum = ChDriver.Codec.cityhash128([header])
      binary = checksum <> header

      assert {:error, {:invalid_compressed_size, 3}} = Block.decode(binary)
    end
  end

  defp corrupt_byte(binary, index) do
    <<prefix::binary-size(index), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 0xFF)::8, suffix::binary>>
  end
end
