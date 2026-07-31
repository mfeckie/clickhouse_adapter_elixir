defmodule ChDriver.ArrayTest do
  @moduledoc """
  Live integration coverage for `Array(T)` column decoding against a real
  ClickHouse table: a real `CREATE TABLE` / `INSERT` / `SELECT` round-trip
  through `ChDriver.query/2`.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("array")
  end

  test "an Array(UInt32) column round-trips non-empty and empty arrays through a real table", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, xs Array(UInt32)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, [1,2,3]), (2, []), (3, [42])"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, xs FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"xs", "Array(UInt32)"}]
    assert rows == [[1, [1, 2, 3]], [2, []], [3, [42]]]
  end

  test "an Array(String) column round-trips through a real table", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, tags Array(String)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, ['a','bb','ccc']), (2, ['solo']), (3, [])"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, tags FROM #{table} ORDER BY id")

    assert rows == [[1, ["a", "bb", "ccc"]], [2, ["solo"]], [3, []]]
  end

  test "an Array(Nullable(UInt32)) column round-trips NULL elements within an array (ClickHouse rejects the reverse nesting, Nullable(Array(T)), outright)",
       %{
         conn: conn,
         table: table
       } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, xs Array(Nullable(UInt32))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, [1, NULL, 3]), (2, [])")

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, xs FROM #{table} ORDER BY id")

    assert rows == [[1, [1, nil, 3]], [2, []]]
  end
end
