defmodule ChDriver.LowCardinalityTest do
  @moduledoc """
  Live integration coverage for `LowCardinality(T)` column decoding
  against a real ClickHouse table -- covering dictionary dedup with
  repeated values, and both the UInt8 and UInt16 dictionary-index width
  tiers (see `ChDriver.Protocol.NativeBlock.decode_low_cardinality/3`'s
  moduledoc for the exact wire format).

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("low_cardinality")
  end

  test "a LowCardinality(String) column with repeated values round-trips correctly (small, UInt8-tier dictionary)",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v LowCardinality(String)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1,'aa'),(2,'bb'),(3,'aa'),(4,'cc'),(5,'bb')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, v FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"v", "LowCardinality(String)"}]

    assert rows == [
             [1, "aa"],
             [2, "bb"],
             [3, "aa"],
             [4, "cc"],
             [5, "bb"]
           ]
  end

  test "a LowCardinality(String) column with >255 distinct values round-trips correctly (forces the UInt16 dictionary-index tier)",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v LowCardinality(String)) ENGINE = Memory"
             )

    values = for i <- 1..400, do: "(#{i}, 'val_#{i}')"

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES " <> Enum.join(values, ","))

    assert {:ok, %{rows: rows}} = ChDriver.query(conn, "SELECT id, v FROM #{table} ORDER BY id")

    expected = for i <- 1..400, do: [i, "val_#{i}"]
    assert rows == expected
  end

  test "an empty LowCardinality(String) result set round-trips correctly (no rows to anchor on)",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v LowCardinality(String)) ENGINE = Memory"
             )

    assert {:ok, %{rows: rows}} = ChDriver.query(conn, "SELECT id, v FROM #{table}")

    assert rows == []
  end
end
