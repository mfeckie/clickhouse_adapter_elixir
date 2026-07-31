defmodule ChDriver.DBConnectionTest do
  use ExUnit.Case, async: false

  alias ChDriver.Result

  @moduletag :integration

  describe "a real DBConnection pool against a live ClickHouse server" do
    setup do
      {:ok, pool} = ChDriver.start_link(pool_size: 2)
      %{pool: pool}
    end

    test "SELECT 1 round-trips through the pool", %{pool: pool} do
      assert {:ok, %Result{columns: columns, rows: rows, num_rows: 1}} =
               ChDriver.query(pool, "SELECT 1")

      assert columns == [{"1", "UInt8"}]
      assert rows == [[1]]
    end

    test "SELECT number FROM system.numbers LIMIT 5 round-trips through the pool", %{
      pool: pool
    } do
      assert {:ok, %Result{rows: rows, num_rows: 5}} =
               ChDriver.query(pool, "SELECT number FROM system.numbers LIMIT 5")

      assert rows == [[0], [1], [2], [3], [4]]
    end

    test "several sequential queries all succeed", %{pool: pool} do
      for n <- 1..10 do
        assert {:ok, %Result{rows: [[^n]]}} = ChDriver.query(pool, "SELECT #{n}")
      end
    end

    test "an invalid query returns an ordinary error without killing the pool", %{pool: pool} do
      assert {:error, %ChDriver.Error{}} = ChDriver.query(pool, "SELEKT 1")

      # the pool itself is still healthy afterwards
      assert {:ok, %Result{rows: [[1]]}} = ChDriver.query(pool, "SELECT 1")
    end

    test "concurrent queries across the pool all succeed", %{pool: pool} do
      results =
        1..8
        |> Task.async_stream(fn n -> ChDriver.query(pool, "SELECT #{n}") end, max_concurrency: 8)
        |> Enum.map(fn {:ok, result} -> result end)

      for {result, n} <- Enum.zip(results, 1..8) do
        assert {:ok, %Result{rows: [[^n]]}} = result
      end
    end

    test "ping/1 succeeds against a checked-out connection state" do
      {:ok, conn} = ChDriver.Connection.connect()
      on_exit(fn -> ChDriver.Connection.close(conn.socket) end)

      assert :ok = ChDriver.Connection.ping(conn)
    end
  end

  describe "query!/2,3,4 against a live ClickHouse server" do
    setup do
      {:ok, pool} = ChDriver.start_link(pool_size: 2)
      %{pool: pool}
    end

    test "returns the %Result{} directly on success", %{pool: pool} do
      assert %Result{columns: columns, rows: rows} = ChDriver.query!(pool, "SELECT 1")

      assert columns == [{"1", "UInt8"}]
      assert rows == [[1]]
    end

    test "raises the underlying ChDriver.Error (not a wrapped/generic error) on failure", %{
      pool: pool
    } do
      assert_raise ChDriver.Error, fn ->
        ChDriver.query!(pool, "SELEKT 1")
      end
    end
  end

  describe "heavier concurrent load across a bigger pool" do
    test "many more concurrent queries than connections still pair each caller with its own result" do
      {:ok, pool} = ChDriver.start_link(pool_size: 10)

      # 200 concurrent callers against 10 connections -- well beyond the
      # earlier 8-tasks/2-connections test -- each asking for a distinct,
      # easily-checked value. Since ClickHouse's native protocol is
      # unpipelined (one query in flight per socket), a response-mixing bug
      # (connection A's reader accidentally consuming connection B's bytes,
      # or a pooled connection being handed out to two callers at once)
      # would show up here as a caller getting back a value that isn't its
      # own.
      results =
        1..200
        |> Task.async_stream(fn n -> {n, ChDriver.query(pool, "SELECT #{n} AS n")} end,
          max_concurrency: 50,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 200

      for {n, result} <- results do
        assert {:ok, %Result{rows: [[^n]]}} = result
      end
    end
  end

  describe "reconnect after a forced disconnect" do
    test "the pool detects a killed socket and reconnects on the next query" do
      marker = make_ref()

      {:ok, pool} =
        ChDriver.start_link(
          pool_size: 1,
          backoff_min: 0,
          backoff_max: 100,
          test_marker: marker
        )

      assert {:ok, %Result{rows: [[1]]}} = ChDriver.query(pool, "SELECT 1")

      # Reach into the single pooled connection and yank the socket out from
      # under DBConnection -- simulating a server-side disconnect or network
      # blip. There's no supported public API for this, so we find the
      # connection's `DBConnection.Connection` gen_statem process (tagged by
      # a unique `:test_marker` opt so we don't accidentally grab a
      # connection started by another test) and reach into its state for
      # the raw socket.
      conn_pid = find_connection_pid!(marker)
      {_, %{state: %{socket: socket}}} = :sys.get_state(conn_pid)
      assert is_port(socket)
      :ok = :gen_tcp.close(socket)

      # The query in flight on the now-dead socket must not hang or crash
      # the caller: handle_execute/4 sees the closed-socket error from
      # ChDriver.Connection.query/2 (a plain `{:error, :closed}`, not a
      # decoded ChDriver.Error) and returns `{:disconnect, ...}`, which
      # DBConnection surfaces to this caller as an ordinary
      # `{:error, %DBConnection.ConnectionError{}}` -- per DBConnection's
      # contract, `:disconnect` reports the error to the current caller and
      # separately tears down/restarts the connection for the *next*
      # checkout, it does not retry this call transparently.
      assert {:error, %DBConnection.ConnectionError{}} =
               ChDriver.query(pool, "SELECT 2", [], timeout: 5_000)

      # Give the pool a moment to run its (backoff_min: 0) reconnect.
      wait_until(fn ->
        case :sys.get_state(conn_pid) do
          {_, %{state: %{socket: new_socket}}} -> is_port(new_socket) and new_socket != socket
          _ -> false
        end
      end)

      # The pool is healthy again on a genuinely new socket -- confirms it
      # actually reconnected, not just recovered/reused the old one.
      assert {:ok, %Result{rows: [[3]]}} = ChDriver.query(pool, "SELECT 3", [], timeout: 5_000)
    end

    test "the pool survives several repeated disconnect/reconnect cycles in a row" do
      marker = make_ref()

      {:ok, pool} =
        ChDriver.start_link(
          pool_size: 1,
          backoff_min: 0,
          backoff_max: 100,
          test_marker: marker
        )

      assert {:ok, %Result{rows: [[0]]}} = ChDriver.query(pool, "SELECT 0")

      conn_pid = find_connection_pid!(marker)

      Enum.reduce(1..4, nil, fn n, previous_socket ->
        {_, %{state: %{socket: socket}}} = :sys.get_state(conn_pid)
        assert is_port(socket)
        assert socket != previous_socket

        :ok = :gen_tcp.close(socket)

        # This particular call surfaces the disconnect as an ordinary error
        # to the caller (per DBConnection's :disconnect contract, same as
        # the single-cycle test above); the pool reconnects behind the
        # scenes for the *next* checkout.
        assert {:error, %DBConnection.ConnectionError{}} =
                 ChDriver.query(pool, "SELECT #{n}", [], timeout: 5_000)

        wait_until(fn ->
          case :sys.get_state(conn_pid) do
            {_, %{state: %{socket: new_socket}}} -> is_port(new_socket) and new_socket != socket
            _ -> false
          end
        end)

        assert {:ok, %Result{rows: [[^n]]}} =
                 ChDriver.query(pool, "SELECT #{n}", [], timeout: 5_000)

        socket
      end)
    end
  end

  defp wait_until(fun, tries \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition did not become true in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end

  # Finds the `DBConnection.Connection` gen_statem process for a pool
  # started with `test_marker: marker` in its opts. Filters `Process.list/0`
  # down to gen_statem processes started via `DBConnection.Connection.init/1`
  # (via `:proc_lib.translate_initial_call/1`, the standard way to identify
  # a process's behaviour module without a registered name) before matching
  # on the marker, so this can't accidentally pick up an unrelated
  # gen_statem process running elsewhere in the VM.
  defp find_connection_pid!(marker) do
    pid =
      Process.list()
      |> Enum.filter(fn p ->
        :proc_lib.translate_initial_call(p) == {DBConnection.Connection, :init, 1}
      end)
      |> Enum.find(fn p ->
        case :sys.get_state(p, 500) do
          {_, %{mod: ChDriver.DBConnection, opts: opts}} ->
            Keyword.get(opts, :test_marker) == marker

          _ ->
            false
        end
      end)

    refute is_nil(pid),
           "could not find the pooled connection process for marker #{inspect(marker)}"

    pid
  end
end
