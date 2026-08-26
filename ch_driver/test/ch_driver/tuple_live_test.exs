defmodule ChDriver.TupleLiveTest do
  @moduledoc """
  Live integration coverage for `Tuple(...)` and
  `LowCardinality(Nullable(T))` columns against a real ClickHouse table,
  round-tripping through `CREATE TABLE`/`INSERT`/`SELECT` rather than
  decoding captured bytes (which `ChDriver.TupleTest` and
  `ChDriver.LowCardinalityNullableTest` cover at the byte level).

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("tuple_live")
  end

  test "a Tuple column round-trips element-wise", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, t Tuple(Int32, String)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, (10, 'a')), (2, (20, 'b'))"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"t", "Tuple(Int32, String)"}]
    assert rows == [[1, {10, "a"}], [2, {20, "b"}]]
  end

  test "a named Tuple decodes positionally", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, t Tuple(n Int32, s String)) ENGINE = Memory"
             )

    assert {:ok, _} = ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, (7, 'x'))")

    assert {:ok, %{rows: [[1, {7, "x"}]]}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table}")
  end

  test "a Tuple with a Nullable element and a nested Map", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} " <>
                 "(id UInt32, t Tuple(Nullable(String), Map(String, Int32))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, (NULL, {'k': 1})), (2, ('a', {}))"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table} ORDER BY id")

    assert rows == [[1, {nil, %{"k" => 1}}], [2, {"a", %{}}]]
  end

  test "a Tuple whose element hoists a serialization prefix", %{conn: conn, table: table} do
    # The inner LowCardinality's dictionary key version is hoisted to the
    # front of the whole column, ahead of the array's offsets.
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} " <>
                 "(id UInt32, t Tuple(Array(LowCardinality(String)), String)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, (['a', 'b', 'a'], 'x')), (2, ([], 'y'))"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table} ORDER BY id")

    assert rows == [[1, {["a", "b", "a"], "x"}], [2, {[], "y"}]]
  end

  test "a Tuple nested inside an Array", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, xs Array(Tuple(Int32, String))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, [(1, 'a'), (2, 'b')]), (2, [])"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, xs FROM #{table} ORDER BY id")

    assert rows == [[1, [{1, "a"}, {2, "b"}]], [2, []]]
  end

  describe "LowCardinality(Nullable(T))" do
    test "NULLs decode as nil, and an empty string stays distinct from NULL",
         %{conn: conn, table: table} do
      assert {:ok, _} =
               ChDriver.query(
                 conn,
                 "CREATE TABLE #{table} " <>
                   "(id UInt32, s LowCardinality(Nullable(String))) ENGINE = Memory"
               )

      assert {:ok, _} =
               ChDriver.query(
                 conn,
                 "INSERT INTO #{table} VALUES (1, 'a'), (2, NULL), (3, ''), (4, 'a')"
               )

      assert {:ok, %{rows: rows}} =
               ChDriver.query(conn, "SELECT id, s FROM #{table} ORDER BY id")

      assert rows == [[1, "a"], [2, nil], [3, ""], [4, "a"]]
    end

    test "nested inside an Array", %{conn: conn, table: table} do
      assert {:ok, _} =
               ChDriver.query(
                 conn,
                 "CREATE TABLE #{table} " <>
                   "(id UInt32, xs Array(LowCardinality(Nullable(String)))) ENGINE = Memory"
               )

      assert {:ok, _} =
               ChDriver.query(
                 conn,
                 "INSERT INTO #{table} VALUES (1, ['a', NULL]), (2, ['b'])"
               )

      assert {:ok, %{rows: rows}} =
               ChDriver.query(conn, "SELECT id, xs FROM #{table} ORDER BY id")

      assert rows == [[1, ["a", nil]], [2, ["b"]]]
    end
  end
end
