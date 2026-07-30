defmodule ChCodecTest do
  use ExUnit.Case, async: true

  describe "lz4_compress/1 and lz4_decompress/2" do
    test "round trips arbitrary data" do
      data = String.duplicate("the quick brown fox jumps over the lazy dog, ", 100)

      compressed = ChCodec.lz4_compress(data)
      assert {:ok, ^data} = ChCodec.lz4_decompress(compressed, byte_size(data))
    end

    test "round trips empty input" do
      compressed = ChCodec.lz4_compress("")
      assert {:ok, ""} = ChCodec.lz4_decompress(compressed, 0)
    end

    test "returns an error tuple for a bogus uncompressed_size" do
      compressed = ChCodec.lz4_compress(String.duplicate("abc", 100))
      assert {:error, _reason} = ChCodec.lz4_decompress(compressed, 1)
    end
  end

  describe "cityhash128/1" do
    # Cross-checked against cityhash-rs's port of Google's official CityHash
    # v1.0.3 test suite (empty input, row 0: expected[3]/expected[4]), then
    # repacked into ClickHouse's on-wire byte order (first/second as
    # little-endian halves) -- see native/chcodec_native/src/lib.rs.
    test "matches the known CityHash v1.0.3 test vector for empty input" do
      expected =
        <<0x2B, 0x9A, 0xC0, 0x64, 0xFC, 0x9D, 0xF0, 0x3D, 0x29, 0x1E, 0xE5, 0x92, 0xC3, 0x40,
          0xB5, 0x3C>>

      assert ChCodec.cityhash128("") == expected
    end

    test "returns 16 bytes for arbitrary input" do
      assert byte_size(ChCodec.cityhash128("hello clickhouse")) == 16
    end

    test "is deterministic" do
      data = "some clickhouse block payload"
      assert ChCodec.cityhash128(data) == ChCodec.cityhash128(data)
    end
  end
end
