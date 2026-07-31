defmodule ChDriver.CompressionTest do
  use ExUnit.Case, async: true

  alias ChDriver.Connection

  @moduletag :integration

  # Formerly blocked on a CityHash version mismatch in `ChCodec.cityhash128/1`
  # (see the NIF binding in ch_codec/native/chcodec_native/src/lib.rs for the
  # v1.0.2-vs-v1.0.3 story) -- now fixed, so the two previously-skipped tests
  # below are unskipped.

  describe "compression: :lz4 against a live ClickHouse server" do
    setup do
      {:ok, conn} = Connection.connect(compression: :lz4)
      on_exit(fn -> Connection.close(conn.socket) end)
      %{conn: conn}
    end

    test "connect/1 records the negotiated compression on the connection", %{conn: conn} do
      assert conn.compression == :lz4
    end

    test "SELECT 1 still round-trips correctly (compression negotiated, tiny result)", %{
      conn: conn
    } do
      assert {:ok, %{columns: columns, rows: rows}} = Connection.query(conn, "SELECT 1")

      assert columns == [{"1", "UInt8"}]
      assert rows == [[1]]
    end

    test "a large, highly-compressible result set round-trips completely and correctly", %{
      conn: conn
    } do
      # 200k rows of a UInt64 plus its string rendering: large enough (and
      # repetitive enough) that LZ4 must actually do real work -- ClickHouse
      # won't bother emitting the compressed envelope for a payload this
      # size unless the negotiated compression is actually wired up and
      # exercised, not just a code path that happens to no-op on tiny
      # inputs. Currently blocked by the ch_codec checksum bug above (this
      # payload is far larger than the ~64-byte coincidence threshold).
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT number, toString(number) AS s FROM system.numbers LIMIT 200000",
                 recv_timeout: 15_000
               )

      assert columns == [{"number", "UInt64"}, {"s", "String"}]
      assert length(rows) == 200_000
      assert List.first(rows) == [0, "0"]
      assert List.last(rows) == [199_999, "199999"]

      assert Enum.map(rows, fn [n, _s] -> n end) == Enum.to_list(0..199_999)
      assert Enum.map(rows, fn [n, s] -> s == Integer.to_string(n) end) |> Enum.all?()
    end

    test "an inserted/selected table round-trips String and UInt32 columns under compression",
         %{conn: conn} do
      table = "ch_driver_compression_test_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Connection.query(
                 conn,
                 "CREATE TABLE #{table} (id UInt32, name String) ENGINE = Memory"
               )

      on_exit(fn ->
        {:ok, conn} = Connection.connect()
        Connection.query(conn, "DROP TABLE IF EXISTS #{table}")
        Connection.close(conn.socket)
      end)

      assert {:ok, _} =
               Connection.query(
                 conn,
                 "INSERT INTO #{table} VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')"
               )

      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(conn, "SELECT id, name FROM #{table} ORDER BY id")

      assert columns == [{"id", "UInt32"}, {"name", "String"}]
      assert rows == [[1, "alice"], [2, "bob"], [3, "carol"]]
    end

    test "per-query :compression opt can override the connection's own default" do
      {:ok, conn} = Connection.connect(compression: :none)
      on_exit(fn -> Connection.close(conn.socket) end)

      assert {:ok, %{rows: rows}} =
               Connection.query(conn, "SELECT number FROM system.numbers LIMIT 50000",
                 compression: :lz4,
                 recv_timeout: 10_000
               )

      assert length(rows) == 50_000
      assert Enum.map(rows, fn [n] -> n end) == Enum.to_list(0..49_999)
    end
  end

  describe "raw wire evidence that compression is actually negotiated and exercised" do
    test "a Query packet declaring compression makes the server respond with ChNative.Block-enveloped Data blocks" do
      # This is the same reverse-engineering probe used to confirm the
      # negotiation mechanism against live ClickHouse: craft a Query packet
      # with the compression varint set to 1 (Enable), send the empty
      # external-table Data packet wrapped in a ChNative.Block LZ4 envelope
      # (as the server requires once compression is declared enabled), and
      # inspect the raw response bytes for the envelope's checksum/method
      # header rather than trusting the higher-level decode path. This does
      # NOT depend on the ch_codec checksum bug above -- it only inspects
      # raw bytes, it never calls `ChNative.Block.decode/1`.
      assert {:ok, conn} = Connection.connect(compression: :lz4)
      on_exit(fn -> Connection.close(conn.socket) end)

      packet = [
        ChDriver.Protocol.encode_query("SELECT number FROM system.numbers LIMIT 10000",
          compression: :lz4
        ),
        ChDriver.Protocol.encode_empty_data_packet(:lz4)
      ]

      :ok = :gen_tcp.send(conn.socket, packet)

      raw = recv_some(conn.socket, <<>>, 20)
      assert byte_size(raw) > 20

      # Server packet type 1 (Data), then external table name (empty
      # string, one zero byte), then the ChNative.Block envelope: 16-byte
      # CityHash128 checksum, then method byte 0x82 (LZ4) -- see
      # `ChNative.Block`'s moduledoc for the envelope layout.
      assert <<1, 0, _checksum::binary-size(16), 0x82, _rest::binary>> = raw
    end
  end

  describe "regression coverage for the ch_codec cityhash bug" do
    test "a real compressed block's checksum verifies correctly, and LZ4 decompresses it" do
      # Captures one real compressed Data block (100 rows, well past the
      # ~64-byte threshold where CityHash v1.0.2/v1.0.3 diverge -- see
      # ch_codec/native/chcodec_native/src/lib.rs's cityhash128/1 binding).
      # Regression test: both the checksum must verify AND LZ4 must
      # decompress correctly.
      assert {:ok, conn} = Connection.connect(compression: :lz4)
      on_exit(fn -> Connection.close(conn.socket) end)

      packet = [
        ChDriver.Protocol.encode_query("SELECT number FROM system.numbers LIMIT 100",
          compression: :lz4
        ),
        ChDriver.Protocol.encode_empty_data_packet(:lz4)
      ]

      :ok = :gen_tcp.send(conn.socket, packet)

      raw = recv_some(conn.socket, <<>>, 20)

      # Skip past the header (0-row) block: packet type + table name +
      # ChNative.Block envelope, whose own compressed_size tells us how far
      # to skip.
      <<1, 0, _checksum1::binary-size(16), _method1::8, header_compressed_size::little-32,
        _header_uncompressed_size::little-32, after_header_envelope::binary>> = raw

      header_payload_size = header_compressed_size - 9
      <<_header_payload::binary-size(header_payload_size), rest::binary>> = after_header_envelope

      # Now at the real (100-row) Data block: packet type + table name +
      # envelope.
      <<1, 0, checksum::binary-size(16), method::8, compressed_size::little-32,
        uncompressed_size::little-32, after_data_header::binary>> = rest

      payload_size = compressed_size - 9
      <<payload::binary-size(payload_size), _rest::binary>> = after_data_header

      assert method == 0x82

      # The checksum comparison ChNative.Block.decode/1 performs internally
      # -- reproduced here directly against ChCodec to confirm it now matches
      # on this real (non-tiny) block.
      envelope_header = <<method::8, compressed_size::little-32, uncompressed_size::little-32>>
      computed_checksum = ChCodec.cityhash128([envelope_header, payload])
      assert computed_checksum == checksum

      # LZ4 decompression itself, however, is completely unaffected: it
      # recovers exactly `uncompressed_size` bytes of plausible-looking
      # Native block data (starts with the expected BlockInfo bytes).
      assert {:ok, decompressed} = ChCodec.lz4_decompress(payload, uncompressed_size)
      assert byte_size(decompressed) == uncompressed_size
      assert <<1, 0, 2, -1::signed-little-32, 0, _rest::binary>> = decompressed
    end
  end

  defp recv_some(_socket, acc, 0), do: acc

  defp recv_some(socket, acc, n) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_some(socket, acc <> data, n - 1)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
    end
  end
end
