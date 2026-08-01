defmodule ChDriver.SettingsTest do
  @moduledoc """
  Integration coverage for `clickhouse_adapter_elixir-4rp`: the `:settings`
  opt that applies real ClickHouse server settings (e.g.
  `settings: [{"async_insert", "0"}]`) via the wire protocol, instead of
  requiring callers to inline a `SETTINGS x = y` clause into raw SQL text.

  Two independently observable, real-server effects are used to prove the
  settings actually reach ClickHouse (see `Protocol.Messages`'s
  `@setting_flag` doc comment for how the wire-format flag byte for a real
  setting was determined -- empirically, against this same live server):

    * `max_block_size` changes how many wire-protocol Data blocks a large
      `SELECT` is chunked into (checked at the `ChDriver.Connection` level
      via `start_stream/3`, and at the public `ChDriver.stream/4` level).
    * `async_insert` changes whether an `INSERT` is durable (and therefore
      visible to an immediately-following `SELECT`) before the query
      response returns -- exactly the behavior
      `clickhouse_adapter_ecto/test/integration/stream_test.exs` used to
      need a `SETTINGS async_insert = 0` SQL-text workaround for.
  """

  use ExUnit.Case, async: false

  alias ChDriver.Connection

  @moduletag :integration

  describe "Connection.query/3 :settings opt" do
    test "async_insert=0 makes an INSERT durable before the response returns (checked via ChDriver.query/4)" do
      {:ok, pool} = ChDriver.start_link(pool_size: 1)
      table = "ch_driver_settings_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        ChDriver.query(
          pool,
          "CREATE TABLE #{table} (id UInt64) ENGINE = MergeTree ORDER BY id"
        )

      on_exit(fn ->
        {:ok, conn} = Connection.connect()
        Connection.query(conn, "DROP TABLE IF EXISTS #{table}")
        Connection.close(conn.socket)
      end)

      {:ok, _} =
        ChDriver.query(pool, "INSERT INTO #{table} VALUES (1)", [],
          settings: [{"async_insert", "0"}]
        )

      {:ok, %ChDriver.Result{rows: rows}} =
        ChDriver.query(pool, "SELECT count() FROM #{table}")

      assert rows == [[1]]
    end

    test "async_insert=1 with wait_for_async_insert=0 does NOT make the insert immediately visible (sanity check on the opposite setting)" do
      {:ok, conn} = Connection.connect()
      table = "ch_driver_settings_test_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Connection.query(
          conn,
          "CREATE TABLE #{table} (id UInt64) ENGINE = MergeTree ORDER BY id"
        )

      on_exit(fn ->
        {:ok, conn} = Connection.connect()
        Connection.query(conn, "DROP TABLE IF EXISTS #{table}")
        Connection.close(conn.socket)
      end)

      {:ok, _} =
        Connection.query(conn, "INSERT INTO #{table} VALUES (1)",
          settings: [{"async_insert", "1"}, {"wait_for_async_insert", "0"}]
        )

      {:ok, %{rows: rows}} = Connection.query(conn, "SELECT count() FROM #{table}")

      # This is the behavior this whole bead exists because of: 26.7's
      # default (`async_insert = 1`) does NOT guarantee the row is visible
      # immediately -- proving the :settings opt genuinely reaches the
      # server rather than being silently ignored.
      assert rows == [[0]]

      Connection.close(conn.socket)
    end

    test "max_block_size chunks a large SELECT into multiple Data blocks" do
      {:ok, conn} = Connection.connect()
      on_exit(fn -> Connection.close(conn.socket) end)

      {:ok, stream} =
        Connection.start_stream(conn, "SELECT number FROM system.numbers LIMIT 1000",
          settings: [{"max_block_size", "50"}]
        )

      {blocks, total_rows} = drain(conn.socket, stream, 0, 0)

      assert blocks > 1
      assert total_rows == 1000
    end
  end

  describe "connection-level default :settings, merged with per-call overrides" do
    test "Connection.connect/1's :settings applies to every query on that connection by default" do
      {:ok, conn} = Connection.connect(settings: [{"max_block_size", "50"}])
      on_exit(fn -> Connection.close(conn.socket) end)

      {:ok, stream} =
        Connection.start_stream(conn, "SELECT number FROM system.numbers LIMIT 1000")

      {blocks, total_rows} = drain(conn.socket, stream, 0, 0)

      assert blocks > 1
      assert total_rows == 1000
    end

    test "a per-call setting with the same name overrides the connection-level default" do
      {:ok, conn} = Connection.connect(settings: [{"max_block_size", "50"}])
      on_exit(fn -> Connection.close(conn.socket) end)

      {:ok, stream} =
        Connection.start_stream(conn, "SELECT number FROM system.numbers LIMIT 1000",
          settings: [{"max_block_size", "1000"}]
        )

      {blocks, total_rows} = drain(conn.socket, stream, 0, 0)

      # The connection-level default alone (max_block_size=50) chunks a
      # 1000-row `system.numbers` result into ~20 blocks (see the test
      # above). Overriding it per-call to 1000 raises the block size back
      # up, so far fewer blocks come back -- proving the per-call value
      # won, not the connection default. `system.numbers` streams via
      # multiple parallel-generator threads even under a single large
      # max_block_size, so this doesn't collapse to exactly one block, but
      # it's decisively fewer than the max_block_size=50 case.
      assert blocks < 10
      assert total_rows == 1000
    end
  end

  describe "ChDriver.stream/4 (public API, through the DBConnection/pool layer)" do
    test "settings: [{\"max_block_size\", \"50\"}] chunks the stream through the pool" do
      {:ok, pool} = ChDriver.start_link(pool_size: 1)

      {block_count, total_rows} =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream("SELECT number FROM system.numbers LIMIT 1000", [],
            settings: [{"max_block_size", "50"}]
          )
          |> Enum.reduce({0, 0}, fn %ChDriver.Result{rows: rows}, {blocks, total} ->
            {blocks + 1, total + length(rows)}
          end)
        end)

      assert block_count > 1
      assert total_rows == 1000
    end
  end

  defp drain(socket, stream, blocks, rows) do
    case Connection.stream_fetch(socket, stream) do
      {:cont, block, new_stream} ->
        drain(socket, new_stream, blocks + 1, rows + length(block.rows))

      {:halt, block, _new_stream} ->
        {blocks + 1, rows + length(block.rows)}
    end
  end
end
