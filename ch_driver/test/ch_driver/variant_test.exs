defmodule ChDriver.VariantTest do
  @moduledoc """
  Live integration coverage for `Variant(T1, ..., Tn)` column decoding
  against a real ClickHouse table, including the
  `Map(String, Variant(...))` shape that motivated adding support.

  A `Variant` column is serialized as a discriminator byte per row
  (the 0-based index of the active alternative in the *type name's* order,
  or `255` for NULL), followed by one contiguous sub-column per
  alternative holding only the rows that selected it, in alternative
  order. Empty alternatives contribute no bytes at all, which is why the
  decoder has to count discriminators before reading any sub-column.

  Note ClickHouse sorts a `Variant`'s alternatives alphabetically when it
  normalizes the type name, so the discriminator order follows the name as
  reported on the wire, not the order originally written in DDL.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first, and `allow_experimental_variant_type` / `enable_variant_type`
  on the server (default-on in recent versions).
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  @variant "Variant(Bool, Int32, String)"

  setup do
    setup_table("variant")
  end

  test "a Variant column decodes each alternative and NULL", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v #{@variant}) ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, true), (2, 42), (3, 'hi'), (4, NULL)",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, v FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"v", @variant}]

    assert rows == [
             [1, true],
             [2, 42],
             [3, "hi"],
             [4, nil]
           ]
  end

  test "a Variant column with only one populated alternative decodes", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v #{@variant}) ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} SELECT number, number::Int32 FROM numbers(5)",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT v FROM #{table} ORDER BY id")

    assert rows == [[0], [1], [2], [3], [4]]
  end

  test "an all-NULL Variant column reads no sub-column bytes", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v #{@variant}) ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, NULL), (2, NULL)", [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{rows: rows}} = ChDriver.query(conn, "SELECT v FROM #{table} ORDER BY id")

    assert rows == [[nil], [nil]]
  end

  test "an empty result set for a Variant column decodes to no rows", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, v #{@variant}) ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{rows: []}} = ChDriver.query(conn, "SELECT v FROM #{table}")
  end

  test "Map(String, Variant(...)) round-trips mixed-typed values", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, details Map(String, #{@variant})) " <>
                 "ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, {'ok': true, 'count': 42, 'name': 'widget'}), (2, {})",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, details FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"details", "Map(String, #{@variant})"}]

    assert rows == [
             [1, %{"ok" => true, "count" => 42, "name" => "widget"}],
             [2, %{}]
           ]
  end

  test "Array(Variant(...)) round-trips through the array decoder", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, vs Array(#{@variant})) ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, [true, 42, 'hi']), (2, [])",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, vs FROM #{table} ORDER BY id")

    assert rows == [[1, [true, 42, "hi"]], [2, []]]
  end

  test "the documented workaround writes a heterogeneous map via map(...) with nested CASTs", %{
    conn: conn,
    table: table
  } do
    # A heterogeneous map can't be bound as a parameter at all (see
    # `ChDriver.Params.type/1`, which raises for it). This pins the
    # workaround that error message recommends, so the advice can't rot.
    #
    # The nested CAST is the non-obvious part: ClickHouse converts to a
    # Variant only "from types from this Variant", and `Params.type/1`
    # binds an Elixir integer as Int64 and a boolean as UInt8 -- neither is
    # a member of Variant(Bool, Int32, String). Casting straight to the
    # Variant fails with "Cannot convert type Int64 to Variant(...)", so
    # each value is cast to its exact member type first.
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, details Map(String, #{@variant})) " <>
                 "ENGINE = Memory",
               [],
               settings: [{"enable_variant_type", "1"}]
             )

    member_type = fn
      value when is_boolean(value) -> "Bool"
      value when is_integer(value) -> "Int32"
      value when is_binary(value) -> "String"
    end

    details = %{"ok" => true, "count" => 42, "name" => "widget"}

    {pairs, params} =
      details
      |> Enum.map(fn {key, value} ->
        {"?, CAST(CAST(?, '#{member_type.(value)}'), '#{@variant}')", [key, value]}
      end)
      |> Enum.unzip()

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (?, map(#{Enum.join(pairs, ", ")}))",
               [1 | List.flatten(params)],
               settings: [{"enable_variant_type", "1"}]
             )

    assert {:ok, %{rows: [[1, ^details]]}} =
             ChDriver.query(conn, "SELECT id, details FROM #{table}")
  end

  test "a Bool column decodes to a boolean", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, b Bool, nb Nullable(Bool)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, true, false), (2, false, NULL)"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, b, nb FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"b", "Bool"}, {"nb", "Nullable(Bool)"}]
    assert rows == [[1, true, false], [2, false, nil]]
  end
end
