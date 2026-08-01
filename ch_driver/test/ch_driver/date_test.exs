defmodule ChDriver.DateTest do
  @moduledoc """
  Live integration coverage for `Date` column decoding/encoding against a
  real ClickHouse table -- the day-count decode
  (`ChDriver.Types.Registry.column_codec("Date")`) round-trips real dates,
  including the epoch itself and a `Date.t()` bound as a query parameter.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("date")
  end

  test "a Date column round-trips real dates, including the Unix epoch", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, d Date) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, '2024-03-15'), (2, '1970-01-01'), (3, '1970-01-02'), (4, '2149-06-06')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, d FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"d", "Date"}]

    assert rows == [
             [1, ~D[2024-03-15]],
             [2, ~D[1970-01-01]],
             [3, ~D[1970-01-02]],
             [4, ~D[2149-06-06]]
           ]
  end

  test "a Nullable(Date) column distinguishes NULL from a real date", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, d Nullable(Date)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, NULL), (2, '2024-03-15')"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, d FROM #{table} ORDER BY id")

    assert rows == [[1, nil], [2, ~D[2024-03-15]]]
  end

  test "a function returning Date (toStartOfWeek) decodes without erroring", %{conn: conn} do
    assert {:ok, %{columns: columns, rows: [[value]]}} =
             ChDriver.query(conn, "SELECT toStartOfWeek(toDateTime('2024-03-15 12:00:00'))")

    assert columns == [{"toStartOfWeek(toDateTime('2024-03-15 12:00:00'))", "Date"}]
    assert value == ~D[2024-03-10]
  end

  test "a Date.t() bound as a query parameter round-trips through insert and select", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, d Date) ENGINE = Memory"
             )

    date = ~D[2024-03-15]

    assert {:ok, _} = ChDriver.query(conn, "INSERT INTO #{table} VALUES (?, ?)", [1, date])

    assert {:ok, %{rows: rows}} = ChDriver.query(conn, "SELECT id, d FROM #{table}")

    assert rows == [[1, date]]
  end
end
