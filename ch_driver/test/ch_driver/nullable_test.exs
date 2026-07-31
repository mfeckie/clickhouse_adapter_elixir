defmodule ChDriver.NullableTest do
  @moduledoc """
  Live integration coverage for `Nullable(T)` column decoding against a
  real ClickHouse table -- complements the `CAST(...)`-based unit-ish
  coverage in `query_test.exs` with an actual `CREATE TABLE` / `INSERT` /
  `SELECT` round-trip through `ChDriver.query/2`.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_nullable_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
  end

  test "a Nullable(UInt32) column round-trips NULL and non-null values through a real table", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, value Nullable(UInt32)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, 42), (2, NULL), (3, 0)"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, value FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"value", "Nullable(UInt32)"}]
    assert rows == [[1, 42], [2, nil], [3, 0]]
  end

  test "a Nullable(String) column round-trips NULL and non-null values through a real table", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, label Nullable(String)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, 'hello'), (2, NULL)"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, label FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"label", "Nullable(String)"}]
    assert rows == [[1, "hello"], [2, nil]]
  end

  test "an all-NULL Nullable column round-trips correctly (no non-null values to anchor on)", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, value Nullable(Int32)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, NULL), (2, NULL)")

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, value FROM #{table} ORDER BY id")

    assert rows == [[1, nil], [2, nil]]
  end
end
