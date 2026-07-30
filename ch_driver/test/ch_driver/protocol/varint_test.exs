defmodule ChDriver.Protocol.VarintTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ChDriver.Protocol.Varint

  describe "encode/1" do
    test "encodes 0 as a single zero byte" do
      assert Varint.encode(0) == <<0>>
    end

    test "encodes values that fit in a single byte (< 128)" do
      assert Varint.encode(1) == <<1>>
      assert Varint.encode(63) == <<63>>
      assert Varint.encode(127) == <<127>>
    end

    test "encodes the 7-bit boundary (128) as two bytes" do
      # 128 = 0b1000_0000 -> low 7 bits = 0 with continuation, then 1
      assert Varint.encode(128) == <<0x80, 0x01>>
      assert Varint.encode(129) == <<0x81, 0x01>>
    end

    test "encodes values just below and at the 14-bit boundary (16384)" do
      assert Varint.encode(16_383) == <<0xFF, 0x7F>>
      assert Varint.encode(16_384) == <<0x80, 0x80, 0x01>>
    end

    test "encodes values just below and at the 21-bit boundary (2097152)" do
      assert Varint.encode(2_097_151) == <<0xFF, 0xFF, 0x7F>>
      assert Varint.encode(2_097_152) == <<0x80, 0x80, 0x80, 0x01>>
    end

    test "encodes a realistic ClickHouse revision" do
      # 54465 = 0xD4C1 -> binary 1101_0100_1100_0001
      assert Varint.encode(54_465) == <<0xC1, 0xA9, 0x03>>
    end

    test "encodes large values spanning many bytes" do
      big = 1 <<< 40
      assert {:ok, ^big, <<>>} = Varint.decode(Varint.encode(big))
    end
  end

  describe "decode/1" do
    test "decodes a single zero byte as 0" do
      assert Varint.decode(<<0>>) == {:ok, 0, <<>>}
    end

    test "decodes and leaves trailing bytes untouched" do
      assert Varint.decode(<<5, 1, 2, 3>>) == {:ok, 5, <<1, 2, 3>>}
    end

    test "decodes multi-byte varints crossing the 7-bit boundary" do
      assert Varint.decode(<<0x80, 0x01>>) == {:ok, 128, <<>>}
      assert Varint.decode(<<0xFF, 0x7F>>) == {:ok, 16_383, <<>>}
    end

    test "decodes multi-byte varints crossing the 14-bit boundary" do
      assert Varint.decode(<<0x80, 0x80, 0x01>>) == {:ok, 16_384, <<>>}
    end

    test "decodes multi-byte varints crossing the 21-bit boundary" do
      assert Varint.decode(<<0x80, 0x80, 0x80, 0x01>>) == {:ok, 2_097_152, <<>>}
    end

    test "reports :incomplete when the continuation bit is never cleared" do
      assert Varint.decode(<<0x80>>) == {:incomplete, <<>>}
      assert Varint.decode(<<0x80, 0x80>>) == {:incomplete, <<>>}
      assert Varint.decode(<<>>) == {:incomplete, <<>>}
    end
  end

  describe "round-trip property" do
    test "encode/decode round-trips for a broad sweep of values including all boundaries" do
      boundary_values = [
        0,
        1,
        63,
        127,
        128,
        129,
        16_383,
        16_384,
        16_385,
        2_097_151,
        2_097_152,
        2_097_153,
        268_435_455,
        268_435_456,
        54_465,
        1 <<< 35,
        (1 <<< 42) - 1
      ]

      random_values = for _ <- 1..500, do: :rand.uniform(1 <<< 48)

      for value <- boundary_values ++ random_values do
        encoded = Varint.encode(value)
        assert {:ok, ^value, <<>>} = Varint.decode(encoded)
      end
    end

    test "decode is unaffected by trailing garbage after a valid varint" do
      for value <- [0, 1, 127, 128, 16_384, 54_465] do
        encoded = Varint.encode(value)
        trailer = <<1, 2, 3, 255>>
        assert {:ok, ^value, ^trailer} = Varint.decode(encoded <> trailer)
      end
    end
  end

  describe "encode_string/1 and decode_string/1" do
    test "round-trips the empty string" do
      encoded = Varint.encode_string("") |> IO.iodata_to_binary()
      assert encoded == <<0>>
      assert Varint.decode_string(encoded) == {:ok, "", <<>>}
    end

    test "round-trips a short ascii string" do
      encoded = Varint.encode_string("default") |> IO.iodata_to_binary()
      assert Varint.decode_string(encoded) == {:ok, "default", <<>>}
    end

    test "round-trips a string long enough to need a multi-byte length varint" do
      long_string = String.duplicate("x", 200)
      encoded = Varint.encode_string(long_string) |> IO.iodata_to_binary()
      assert Varint.decode_string(encoded) == {:ok, long_string, <<>>}
    end

    test "round-trips arbitrary binary content, not just valid UTF-8" do
      binary = <<0, 255, 1, 254, 128, 127>>
      encoded = Varint.encode_string(binary) |> IO.iodata_to_binary()
      assert Varint.decode_string(encoded) == {:ok, binary, <<>>}
    end

    test "leaves trailing bytes after the string untouched" do
      encoded = Varint.encode_string("abc") |> IO.iodata_to_binary()
      assert Varint.decode_string(encoded <> <<9, 9>>) == {:ok, "abc", <<9, 9>>}
    end

    test "reports :incomplete when the length prefix is present but string bytes are missing" do
      # length varint says 10 bytes follow, but none are supplied
      assert Varint.decode_string(<<10>>) == {:incomplete, <<10>>}
    end

    test "reports :incomplete when even the length prefix is incomplete" do
      assert Varint.decode_string(<<0x80>>) == {:incomplete, <<0x80>>}
    end
  end
end
