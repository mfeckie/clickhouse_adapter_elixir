defmodule ChDriver.TestCase do
  @moduledoc """
  Per-test setup helpers for `ch_driver`'s own integration suite: each test
  wants one throwaway table (or a raw connection) for its own duration, not
  a whole-module shared-table cycle -- see
  `Ecto.Adapters.ClickHouse.TestCase`/`ConcurrentTestCase`
  (`clickhouse_adapter_ecto/test/support/`) for that heavier pattern, used at
  the Ecto adapter layer above this one.

  ## Why `setup_table/1`'s `on_exit` opens a new connection

  `ChDriver.start_link/1` calls `DBConnection.start_link/2`, which links the
  started pool to its caller -- here, the test process. By the time ExUnit
  runs a test's `on_exit` callbacks, the test process has already exited,
  which kills anything linked to it, including a connection started during
  `setup`. There is nothing left on that connection to send a `DROP TABLE`
  through, so `on_exit` has to open its own connection to issue it.
  """

  @default_connect_opts [hostname: "localhost", port: 9000]

  @doc """
  Starts a `ChDriver` connection for the test, generates a unique table name
  prefixed with `ch_driver_<name>_test_`, and registers an `on_exit` that
  drops that table through a *fresh* connection (see moduledoc for why it
  can't reuse the one returned here). Returns `%{conn: conn, table: table}`,
  ready to be used directly as a `setup` block's return value:

      setup do
        setup_table("array")
      end

  `connect_opts` overrides/extends the default `hostname: "localhost", port:
  9000`.
  """
  @spec setup_table(String.t(), keyword) :: %{conn: DBConnection.conn(), table: String.t()}
  def setup_table(name, connect_opts \\ []) do
    opts = Keyword.merge(@default_connect_opts, connect_opts)

    {:ok, conn} = ChDriver.start_link(opts)
    table = "ch_driver_#{name}_test_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.on_exit(fn ->
      case ChDriver.start_link(opts) do
        {:ok, cleanup_conn} ->
          ChDriver.query(cleanup_conn, "DROP TABLE IF EXISTS #{table}")
          GenServer.stop(cleanup_conn)

        {:error, _reason} ->
          # ClickHouse is already unreachable at teardown time; nothing
          # more useful to do than skip the drop.
          :ok
      end
    end)

    %{conn: conn, table: table}
  end

  @doc """
  Raw-socket counterpart to `setup_table/1`, for test files that talk to
  `ChDriver.Connection.connect/0` directly instead of the pooled
  `ChDriver.start_link/1`. Opens a connection and registers an `on_exit` to
  close it -- safe to reuse as-is here, since closing a socket doesn't
  depend on the test process still being alive the way
  `DBConnection.start_link/2`'s link does.

      setup do
        setup_connection()
      end
  """
  @spec setup_connection() :: %{conn: map}
  def setup_connection do
    {:ok, conn} = ChDriver.Connection.connect()
    ExUnit.Callbacks.on_exit(fn -> ChDriver.Connection.close(conn.socket) end)
    %{conn: conn}
  end
end
