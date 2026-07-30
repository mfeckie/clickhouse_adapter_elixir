defmodule ChDriver.MapTest do
  @moduledoc """
  Live integration coverage for `Map(K, V)` column decoding
  (clickhouse_adapter_elixir-8a2.21) against a real ClickHouse table --
  confirming empty and populated maps round-trip to plain Elixir maps (see
  `ChDriver.Protocol.NativeBlock.decode_map/3`).

  Also confirms live that `Nullable(Map(...))` is rejected by ClickHouse
  outright (same restriction previously found for `Nullable(Array(T))`), so
  `Map(K, V)` has no `Nullable` variant to test here.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_map_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
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
