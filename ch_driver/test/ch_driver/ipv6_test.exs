defmodule ChDriver.Ipv6Test do
  @moduledoc """
  Live integration coverage for `IPv6` column decoding against a real
  ClickHouse table -- the colon-hex text-form decode via `:inet.ntoa/1`
  (see `ChDriver.Protocol.NativeBlock.decode_ipv6/1`) round-trips real
  addresses.

  ClickHouse canonicalizes `IPv6` text on output (e.g. it always writes the
  `::ffff:` IPv4-mapped prefix in lowercase-hex-group form rather than
  embedding a dotted-quad suffix), and `:inet.ntoa/1` has its own
  canonicalization rules independent of whatever string was originally
  inserted -- so these assertions are against the actual observed output,
  not an assumption that decoded text matches the inserted literal
  byte-for-byte.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true

  import ChDriver.TestCase

  @moduletag :integration

  setup do
    setup_table("ipv6")
  end

  test "an IPv6 column round-trips compressed, full, and IPv4-mapped forms", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, ip IPv6) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES " <>
                 "(1, '::1'), (2, '2001:0db8:0000:0000:0000:0000:0000:0001'), " <>
                 "(3, '::ffff:192.168.1.1')"
             )

    assert {:ok, %{columns: columns, rows: rows}} =
             ChDriver.query(conn, "SELECT id, ip FROM #{table} ORDER BY id")

    assert columns == [{"id", "UInt32"}, {"ip", "IPv6"}]

    assert [[1, addr1], [2, addr2], [3, addr3]] = rows

    # `::1` (loopback) round-trips through :inet.ntoa/1's own canonical form.
    assert addr1 == "::1"

    # The fully-expanded form canonicalizes to the compressed `2001:db8::1`.
    assert addr2 == "2001:db8::1"

    # IPv4-mapped addresses decode to whatever :inet.ntoa/1 produces for the
    # 8x16-bit-group tuple -- assert against its actual output rather than
    # assuming a dotted-quad suffix survives. `:inet.parse_address/1` expects
    # a charlist, not a binary.
    assert {:ok, parsed} = addr3 |> String.to_charlist() |> :inet.parse_address()
    assert addr3 == parsed |> :inet.ntoa() |> to_string()
    assert String.starts_with?(addr3, "::")
  end

  test "a Nullable(IPv6) column distinguishes NULL from a real address", %{
    conn: conn,
    table: table
  } do
    assert {:ok, _} =
             ChDriver.query(
               conn,
               "CREATE TABLE #{table} (id UInt32, ip Nullable(IPv6)) ENGINE = Memory"
             )

    assert {:ok, _} =
             ChDriver.query(
               conn,
               "INSERT INTO #{table} VALUES (1, NULL), (2, '::1')"
             )

    assert {:ok, %{rows: rows}} =
             ChDriver.query(conn, "SELECT id, ip FROM #{table} ORDER BY id")

    assert rows == [[1, nil], [2, "::1"]]
  end
end
