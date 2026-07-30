defmodule ChDriver.DecimalTest do
  @moduledoc """
  Live integration coverage for `Decimal(P, S)` column decoding
  (clickhouse_adapter_elixir-8a2.19) against a real ClickHouse table,
  including the fixed-precision `Decimal32(S)`/`Decimal64(S)`/
  `Decimal128(S)` aliases.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_decimal_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
  end

  test "a Decimal(18, 4) column round-trips positive, negative, and near-zero values", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, amount Decimal(18, 4)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, 123.4567), (2, -9.99), (3, -0.0001), (4, 0)"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, amount FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"amount", "Decimal(18, 4)"}]

    assert rows == [
             [1, Decimal.new("123.4567")],
             [2, Decimal.new("-9.9900")],
             [3, Decimal.new("-0.0001")],
             [4, Decimal.new("0.0000")]
           ]
  end

  test "Decimal32/64/128 fixed-precision aliases round-trip through their respective byte widths",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, d32 Decimal32(2), d64 Decimal64(6), " <>
                 "d128 Decimal128(10)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, 21474.83, 123456.123456, 12345678901234567890.1234567890)"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, d32, d64, d128 FROM #{table} ORDER BY id")

    # ClickHouse's own `system.columns`/native-protocol type-name reporting
    # normalizes the fixed-precision aliases to their canonical
    # `Decimal(P, S)` form (confirmed live) -- `parse_decimal/1` still needs
    # to accept the alias spelling too, since a column *created* via
    # `Decimal32(...)`/etc could in principle still be reported back that
    # way by a different ClickHouse version/tool.
    assert columns == [
             {"id", "UInt32"},
             {"d32", "Decimal(9, 2)"},
             {"d64", "Decimal(18, 6)"},
             {"d128", "Decimal(38, 10)"}
           ]

    assert rows == [
             [
               1,
               Decimal.new("21474.83"),
               Decimal.new("123456.123456"),
               Decimal.new("12345678901234567890.1234567890")
             ]
           ]
  end
end
