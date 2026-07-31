defmodule ChDriver.SparseTest do
  @moduledoc """
  Live integration coverage for ClickHouse's "sparse" column serialization
  -- the `has_custom_serialization = 1` wire format
  `ChDriver.Protocol.NativeBlock.decode_sparse/3` decodes (see its
  moduledoc for the byte-level format, which matches ClickHouse's
  `SerializationSparse.cpp`).

  Unlike every other type this driver decodes, sparse serialization can't
  be forced by column *type* alone -- it's a MergeTree storage decision
  ClickHouse makes automatically once a column's default-value ratio
  exceeds `ratio_of_defaults_for_sparse_serialization` (default `0.9`).
  Each test here creates a real `MergeTree` table (the `Memory` engine used
  by this driver's other wrapper-type tests never uses sparse
  serialization at all), inserts default-heavy data, runs `OPTIMIZE TABLE
  ... FINAL` to force ClickHouse to merge down to a single part with its
  steady-state serialization choice, and then asserts via
  `system.parts_columns.serialization_kind` that the column actually *is*
  stored as `Sparse` before trusting the subsequent `SELECT` as a
  meaningful test of this decoder -- otherwise a passing test could just
  mean the column happened to stay `Default`-encoded.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    table = "ch_driver_sparse_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
    end)

    %{conn: conn, table: table}
  end

  # Asserts that `column` on `table` is genuinely stored with `Sparse`
  # serialization -- the precondition every test here depends on to be a
  # meaningful test of `decode_sparse/3` rather than an accidental no-op.
  defp assert_sparse!(conn, table, column) do
    assert {:ok, %{rows: [[kind]]}} =
             ChDriver.query(
               conn,
               "SELECT serialization_kind FROM system.parts_columns " <>
                 "WHERE table = '#{table}' AND column = '#{column}' AND active " <>
                 "ORDER BY serialization_kind DESC LIMIT 1"
             )

    assert kind == "Sparse",
           "expected #{table}.#{column} to be stored with Sparse serialization, got #{inspect(kind)}"
  end

  test "a mostly-default UInt8 flag column round-trips defaults and non-defaults, including runs and boundaries",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               """
               CREATE TABLE #{table} (id UInt32, flag UInt8) ENGINE = MergeTree ORDER BY id
               SETTINGS ratio_of_defaults_for_sparse_serialization = 0.1
               """
             )

    # Non-default values at: row 0 (leading boundary), rows 1-2 (an
    # adjacent run of non-defaults with zero defaults between them), row
    # 500 (an isolated non-default surrounded by long default runs), and
    # row 999 (trailing boundary) -- every shape the sparse offset-stream
    # format (moduledoc) can produce.
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} (id, flag) SELECT number, " <>
                 "multiIf(number = 0, 5, number = 1, 6, number = 2, 7, " <>
                 "number = 500, 9, number = 999, 4, 0) " <>
                 "FROM numbers(1000)"
             )

    assert {:ok, _} = ChDriver.query(conn, "OPTIMIZE TABLE #{table} FINAL")
    assert_sparse!(conn, table, "flag")

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, flag FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"flag", "UInt8"}]
    assert length(rows) == 1000

    expected = fn id ->
      case id do
        0 -> 5
        1 -> 6
        2 -> 7
        500 -> 9
        999 -> 4
        _ -> 0
      end
    end

    assert Enum.all?(rows, fn [id, flag] -> flag == expected.(id) end)
  end

  test "an all-default column (no non-default values at all) round-trips to all zeros", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               """
               CREATE TABLE #{table} (id UInt32, flag UInt8) ENGINE = MergeTree ORDER BY id
               SETTINGS ratio_of_defaults_for_sparse_serialization = 0.1
               """
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} (id, flag) SELECT number, 0 FROM numbers(1000)"
             )

    assert {:ok, _} = ChDriver.query(conn, "OPTIMIZE TABLE #{table} FINAL")
    assert_sparse!(conn, table, "flag")

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, flag FROM #{table} ORDER BY id")

    assert length(rows) == 1000
    assert Enum.all?(rows, fn [_id, flag] -> flag == 0 end)
  end

  test "a mostly-empty String column round-trips default (empty string) and non-default values",
       %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               """
               CREATE TABLE #{table} (id UInt32, name String) ENGINE = MergeTree ORDER BY id
               SETTINGS ratio_of_defaults_for_sparse_serialization = 0.1
               """
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} (id, name) SELECT number, " <>
                 "if(number % 25 = 0, 'x', '') FROM numbers(1000)"
             )

    assert {:ok, _} = ChDriver.query(conn, "OPTIMIZE TABLE #{table} FINAL")
    assert_sparse!(conn, table, "name")

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, name FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"name", "String"}]
    assert length(rows) == 1000

    assert Enum.all?(rows, fn [id, name] ->
             expected = if rem(id, 25) == 0, do: "x", else: ""
             name == expected
           end)
  end

  test "an empty result set against a sparse-encoded table decodes to zero rows", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               """
               CREATE TABLE #{table} (id UInt32, flag UInt8) ENGINE = MergeTree ORDER BY id
               SETTINGS ratio_of_defaults_for_sparse_serialization = 0.1
               """
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} (id, flag) SELECT number, " <>
                 "if(number = 0, 1, 0) FROM numbers(1000)"
             )

    assert {:ok, _} = ChDriver.query(conn, "OPTIMIZE TABLE #{table} FINAL")
    assert_sparse!(conn, table, "flag")

    assert {:ok, %{rows: []}} =
             ChDriver.query(conn, "SELECT id, flag FROM #{table} WHERE id > 999999")
  end
end
