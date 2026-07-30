defmodule ChDriver.QueryTest do
  use ExUnit.Case, async: true

  alias ChDriver.Connection
  alias ChDriver.Error

  @moduletag :integration

  setup do
    {:ok, conn} = Connection.connect()
    on_exit(fn -> Connection.close(conn.socket) end)
    %{conn: conn}
  end

  describe "query/2 against a live ClickHouse server" do
    test "SELECT 1 round-trips to a single UInt8 row", %{conn: conn} do
      assert {:ok, %{columns: columns, rows: rows}} = Connection.query(conn, "SELECT 1")

      assert columns == [{"1", "UInt8"}]
      assert rows == [[1]]
    end

    test "SELECT number FROM system.numbers LIMIT 5 round-trips 5 UInt64 rows", %{conn: conn} do
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(conn, "SELECT number FROM system.numbers LIMIT 5")

      assert columns == [{"number", "UInt64"}]
      assert rows == [[0], [1], [2], [3], [4]]
    end

    test "a String column round-trips", %{conn: conn} do
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(conn, "SELECT 'hello' AS greeting")

      assert columns == [{"greeting", "String"}]
      assert rows == [["hello"]]
    end

    test "multiple columns of mixed types round-trip", %{conn: conn} do
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT number, toString(number) AS s FROM system.numbers LIMIT 3"
               )

      assert columns == [{"number", "UInt64"}, {"s", "String"}]
      assert rows == [[0, "0"], [1, "1"], [2, "2"]]
    end

    test "an invalid query returns a ChDriver.Error instead of raising", %{conn: conn} do
      assert {:error, %Error{} = error} =
               Connection.query(conn, "SELECT nonexistent_column FROM system.numbers LIMIT 1")

      assert error.name in ["DB::Exception", "DB::NetException"]
      assert error.message =~ "nonexistent_column"
      assert is_integer(error.code)
    end

    test "a syntax error also returns a ChDriver.Error", %{conn: conn} do
      assert {:error, %Error{} = error} = Connection.query(conn, "SELEKT 1")

      assert error.name in ["DB::Exception", "DB::NetException"]
      assert is_integer(error.code)
    end

    test "the same connection can run multiple queries sequentially", %{conn: conn} do
      assert {:ok, %{rows: [[1]]}} = Connection.query(conn, "SELECT 1")
      assert {:ok, %{rows: [[2]]}} = Connection.query(conn, "SELECT 2")
      assert {:ok, %{rows: [[3]]}} = Connection.query(conn, "SELECT 3")
    end

    test "a query against a nonexistent table returns a ChDriver.Error", %{conn: conn} do
      assert {:error, %Error{} = error} =
               Connection.query(conn, "SELECT * FROM this_table_does_not_exist_at_all")

      assert error.name == "DB::Exception"
      # DB::Exception::UNKNOWN_TABLE / UNKNOWN_IDENTIFIER family -- either is
      # an acceptable "table isn't there" code depending on analyzer version.
      assert is_integer(error.code)
      assert error.message =~ "this_table_does_not_exist_at_all"
    end

    test "a query returning zero rows still reports correct columns", %{conn: conn} do
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(conn, "SELECT number FROM system.numbers LIMIT 0")

      assert columns == [{"number", "UInt64"}]
      assert rows == []
    end

    # Documents a known driver limitation rather than a bug: NativeBlock's
    # type decoder (see `ChDriver.Protocol.NativeBlock.column_codec/1`) only
    # covers a pragmatic subset of ClickHouse's type system and has no case
    # for `Nullable(...)`. This is *not* a crash or a hang -- the block
    # decoder cleanly surfaces `{:error, {:unsupported_type, ...}}` up
    # through `Connection.query/2,3` -- but it does mean any query touching
    # a Nullable column fails outright today. Adding Nullable support is a
    # driver feature, out of scope for this integration-test-only task; see
    # clickhouse_adapter_elixir-8a2.10 notes.
    test "a Nullable column is a known unsupported type, but fails cleanly (no hang/crash)", %{
      conn: conn
    } do
      assert {:error, {:unsupported_type, "Nullable(String)"}} =
               Connection.query(conn, "SELECT CAST(NULL AS Nullable(String)) AS x")
    end

    test "INSERT via inline VALUES round-trips through a subsequent SELECT", %{conn: conn} do
      table = "ch_driver_insert_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        {:ok, conn} = Connection.connect()
        Connection.query(conn, "DROP TABLE IF EXISTS #{table}")
        Connection.close(conn.socket)
      end)

      assert {:ok, _} =
               Connection.query(
                 conn,
                 "CREATE TABLE #{table} (id UInt32, name String) ENGINE = Memory"
               )

      # NOTE: this is the only supported INSERT path today -- the full
      # statement (including literal row values) is sent as a single Query
      # packet, same as any other query string; ClickHouse itself parses the
      # inline VALUES clause server-side. `Connection.query/2,3` always
      # follows the Query packet with a single *empty* Data packet (see
      # `Protocol.encode_empty_data_packet/0`), so there is no way today to
      # stream row data as a separate Native-format Data block (e.g.
      # `INSERT INTO t FORMAT Native` followed by client-sent Data packets)
      # -- that would require new driver functionality, out of scope here.
      assert {:ok, %{rows: []}} =
               Connection.query(
                 conn,
                 "INSERT INTO #{table} VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')"
               )

      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(conn, "SELECT id, name FROM #{table} ORDER BY id")

      assert columns == [{"id", "UInt32"}, {"name", "String"}]
      assert rows == [[1, "alice"], [2, "bob"], [3, "carol"]]
    end

    test "a large result set spanning multiple Native Data blocks decodes completely", %{
      conn: conn
    } do
      assert {:ok, %{columns: columns, rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT number FROM system.numbers LIMIT 100000",
                 recv_timeout: 15_000
               )

      assert columns == [{"number", "UInt64"}]
      assert length(rows) == 100_000
      assert List.first(rows) == [0]
      assert List.last(rows) == [99_999]
      # every row present, in order, no duplicates/drops/reordering across
      # whatever block boundaries the server chose to split this into.
      assert Enum.map(rows, fn [n] -> n end) == Enum.to_list(0..99_999)
    end
  end
end
