defmodule ChDriver.MapTest do
  @moduledoc """
  Live integration coverage for `Map(K, V)` column decoding against a real
  ClickHouse table -- empty and populated maps round-trip to plain Elixir
  maps (see `ChDriver.Protocol.NativeBlock.decode_map/3`).

  `Nullable(Map(...))` is rejected by ClickHouse outright (same
  restriction as `Nullable(Array(T))`), so `Map(K, V)` has no `Nullable`
  variant to test here.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("map")
  end

  test "a Map(String, UInt32) column round-trips empty and populated maps", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, m Map(String, UInt32)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, {}), (2, {'a':1}), (3, {'a':1,'b':2,'c':3})"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, m FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"m", "Map(String, UInt32)"}]

    assert rows == [
             [1, %{}],
             [2, %{"a" => 1}],
             [3, %{"a" => 1, "b" => 2, "c" => 3}]
           ]
  end

  test "ClickHouse rejects Nullable(Map(...)) outright, mirroring Nullable(Array(T))", %{
    conn: conn,
    table: table
  } do
    assert {:error, _reason} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, m Nullable(Map(String, UInt32))) " <>
                 "ENGINE = Memory"
             )
  end
end
