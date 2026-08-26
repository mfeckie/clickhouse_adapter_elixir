defmodule ChDriver.DateTime64Test do
  @moduledoc """
  Live integration coverage for `DateTime64(P)` column decoding against a
  real ClickHouse table.

  `DateTime64(P)` is a little-endian *signed* Int64 tick count at 10^-P
  second resolution since the Unix epoch -- unlike plain `DateTime`'s
  unsigned whole-second UInt32, it can represent pre-epoch instants
  (negative ticks) and sub-second precision. Decoded values keep their
  full precision via `DateTime.t()`'s microsecond field, so a
  `DateTime64(3)` value loads back with `{ms * 1000, 3}` -- precision `3`
  preserved, not silently widened to `6`.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("datetime64")
  end

  test "a DateTime64(3) column round-trips millisecond precision", %{conn: conn, table: table} do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, t DateTime64(3)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, '2024-03-15 12:34:56.789'), (2, '1970-01-01 00:00:00.000'), " <>
                 "(3, '1969-07-20 20:17:40.500')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"t", "DateTime64(3)"}]

    assert rows == [
             [1, DateTime.new!(~D[2024-03-15], ~T[12:34:56.789], "Etc/UTC")],
             [2, DateTime.new!(~D[1970-01-01], ~T[00:00:00.000], "Etc/UTC")],
             [3, DateTime.new!(~D[1969-07-20], ~T[20:17:40.500], "Etc/UTC")]
           ]

    # Precision is preserved as-is, not widened to microseconds.
    assert [[_, %DateTime{microsecond: {789_000, 3}}] | _] = rows
  end

  test "DateTime64 precisions 0, 6 and 9 each decode at their own resolution", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, p0 DateTime64(0), p6 DateTime64(6), " <>
                 "p9 DateTime64(9)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, '2024-03-15 12:34:56', " <>
                 "'2024-03-15 12:34:56.789789', '2024-03-15 12:34:56.789789789')"
             )

    assert {:ok, %{rows: [[1, p0, p6, p9]]}} =
             ChDriver.query(conn, "SELECT id, p0, p6, p9 FROM #{table}")

    assert p0 == DateTime.new!(~D[2024-03-15], ~T[12:34:56], "Etc/UTC")
    assert p0.microsecond == {0, 0}

    assert p6 == DateTime.new!(~D[2024-03-15], ~T[12:34:56.789789], "Etc/UTC")
    assert p6.microsecond == {789_789, 6}

    # Elixir's DateTime only carries microsecond resolution, so a
    # nanosecond DateTime64(9) truncates to 6 digits.
    assert p9 == DateTime.new!(~D[2024-03-15], ~T[12:34:56.789789], "Etc/UTC")
    assert p9.microsecond == {789_789, 6}
  end

  test "DateTime64 with a timezone argument decodes the same instant", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, t DateTime64(3, 'Europe/London')) " <>
                 "ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(conn, "INSERT INTO #{table} VALUES (1, '2024-03-15 12:34:56.789')")

    assert {:ok, %{columns: columns, rows: [[1, t]]}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table}")

    assert columns == [{"id", "UInt32"}, {"t", "DateTime64(3, 'Europe/London')"}]

    # 12:34:56.789 London time in March is UTC+0 (BST starts Mar 31), so
    # the underlying instant is the same wall clock in UTC here.
    assert t == DateTime.new!(~D[2024-03-15], ~T[12:34:56.789], "Etc/UTC")
  end

  test "a Nullable(DateTime64(3)) column distinguishes NULL from an instant", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, t Nullable(DateTime64(3))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, '2024-03-15 12:34:56.789'), (2, NULL)"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, t FROM #{table} ORDER BY id")

    assert rows == [
             [1, DateTime.new!(~D[2024-03-15], ~T[12:34:56.789], "Etc/UTC")],
             [2, nil]
           ]
  end

  test "an Array(DateTime64(3)) column round-trips through the array decoder", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, ts Array(DateTime64(3))) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, ['2024-03-15 12:34:56.789', '1970-01-01 00:00:00.001']), (2, [])"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, ts FROM #{table} ORDER BY id")

    assert rows == [
             [
               1,
               [
                 DateTime.new!(~D[2024-03-15], ~T[12:34:56.789], "Etc/UTC"),
                 DateTime.new!(~D[1970-01-01], ~T[00:00:00.001], "Etc/UTC")
               ]
             ],
             [2, []]
           ]
  end
end
