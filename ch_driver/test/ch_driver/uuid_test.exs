defmodule ChDriver.UUIDTest do
  @moduledoc """
  Live integration coverage for `UUID` column decoding
  (clickhouse_adapter_elixir-8a2.19) against a real ClickHouse table --
  including the wire's confirmed-live "byte-reverse each 8-byte half"
  layout (see `ChDriver.Protocol.NativeBlock.decode_uuid/1`'s moduledoc).

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_uuid_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
  end

  test "a UUID column round-trips a known literal through a real table", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(conn, "CREATE TABLE #{table} (id UInt32, u UUID) ENGINE = Memory")

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, '61f0c404-5cb3-11e7-907b-a6006ad3dba0'), " <>
                 "(2, '00000000-0000-0000-0000-000000000000')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, u FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"u", "UUID"}]

    assert rows == [
             [1, "61f0c404-5cb3-11e7-907b-a6006ad3dba0"],
             [2, "00000000-0000-0000-0000-000000000000"]
           ]
  end

  test "a UUID generated server-side via generateUUIDv4() round-trips byte-for-byte (compared via ClickHouse's own hex()/lower(), independent of this driver's decoding)",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(conn, "CREATE TABLE #{table} (id UInt32, u UUID) ENGINE = Memory")

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} SELECT 1, generateUUIDv4()"
             )

    assert {:ok, %{rows: [[expected_hex]]}} =
             ChDriver.query(conn, "SELECT lower(hex(u)) FROM #{table}")

    assert {:ok, %{rows: [[1, decoded]]}} =
             ChDriver.query(conn, "SELECT id, u FROM #{table}")

    assert String.replace(decoded, "-", "") == expected_hex
  end
end
