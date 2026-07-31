defmodule ChDriver.FixedStringTest do
  @moduledoc """
  Live integration coverage for `FixedString(N)` column decoding against a
  real ClickHouse table -- including the fact that ClickHouse does *not*
  trim the null-byte padding back out on `SELECT` (see
  `ChDriver.Protocol.NativeBlock.decode_map/3`'s neighboring `FixedString`
  moduledoc for the exact wire-format details).

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_fixed_string_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
  end

  test "a FixedString(5) column round-trips a short value with its null-byte padding preserved verbatim",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, f FixedString(5)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, 'ab'), (2, 'abcde'), (3, '')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, f FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"f", "FixedString(5)"}]

    assert rows == [
             [1, <<"ab", 0, 0, 0>>],
             [2, "abcde"],
             [3, <<0, 0, 0, 0, 0>>]
           ]

    # Every decoded value is exactly N bytes, padding included.
    for [_id, value] <- rows, do: assert(byte_size(value) == 5)
  end

  test "a Nullable(FixedString(N)) column distinguishes NULL from an all-zero-padded value",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, f Nullable(FixedString(3))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, NULL), (2, 'x')")

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, f FROM #{table} ORDER BY id")

    assert rows == [[1, nil], [2, <<"x", 0, 0>>]]
  end
end
