defmodule ChDriver.Ipv4Test do
  @moduledoc """
  Live integration coverage for `IPv4` column decoding against a real
  ClickHouse table -- the dotted-quad text-form decode (see
  `ChDriver.Protocol.NativeBlock.decode_ipv4/1`) round-trips real
  addresses, including the all-zero and all-ones edge cases.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("ipv4")
  end

  test "an IPv4 column round-trips dotted-quad addresses, including 0.0.0.0 and 255.255.255.255",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, ip IPv4) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, '192.168.1.1'), (2, '0.0.0.0'), (3, '255.255.255.255'), (4, '10.0.0.1')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, ip FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"ip", "IPv4"}]

    assert rows == [
             [1, "192.168.1.1"],
             [2, "0.0.0.0"],
             [3, "255.255.255.255"],
             [4, "10.0.0.1"]
           ]
  end

  test "a Nullable(IPv4) column distinguishes NULL from a real address", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, ip Nullable(IPv4)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, NULL), (2, '127.0.0.1')"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, ip FROM #{table} ORDER BY id")

    assert rows == [[1, nil], [2, "127.0.0.1"]]
  end
end
