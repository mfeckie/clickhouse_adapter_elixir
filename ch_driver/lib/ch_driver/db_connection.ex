defmodule ChDriver.DBConnection do
  @moduledoc """
  `DBConnection` behaviour implementation wrapping `ChDriver.Connection`'s
  synchronous request/response socket so it can be used as a normal pooled
  connection.

  ClickHouse's native TCP protocol is a plain, unpipelined request/response
  protocol -- one query in flight per socket at a time -- so this module is
  a thin adapter: `handle_execute/4` calls `ChDriver.Connection.query/2,3`
  and translates its `{:ok, %{columns:, rows:}}` / `{:error, term}` shape
  into DBConnection's `{:ok, query, result, state}` /
  `{:error | :disconnect, exception, state}` contract.

  Socket-level failures (`:gen_tcp` errors such as `:closed`/`:timeout`)
  are treated as `:disconnect` so the pool tears down and reconnects the
  underlying socket; ClickHouse-level query errors (a decoded
  `%ChDriver.Error{}` from an Exception packet) are returned as ordinary
  `:error` results, since the connection itself is still perfectly usable
  for the next query.

  There is no transaction or cursor support in the ClickHouse native
  protocol as used here, so `handle_begin/2`, `handle_commit/2`,
  `handle_rollback/2`, `handle_declare/4`, `handle_fetch/4`, and
  `handle_deallocate/4` are unimplemented stubs that error out rather than
  silently pretending to do something; `handle_status/2` always reports
  `:idle` since there is no transaction state to track.
  """

  @behaviour DBConnection

  alias ChDriver.Connection
  alias ChDriver.Query
  alias ChDriver.Result
  alias DBConnection.ConnectionError

  @impl true
  def connect(opts) do
    case Connection.connect(opts) do
      {:ok, conn} ->
        {:ok, %{socket: conn.socket, server_info: conn.server_info, opts: opts}}

      {:error, reason} ->
        {:error, connection_error("failed to connect to ClickHouse", reason)}
    end
  end

  @impl true
  def disconnect(_err, state) do
    Connection.close(state.socket)
  end

  @impl true
  def checkout(state) do
    # The socket is a plain, synchronous request/response connection with
    # nothing left half-open between queries -- there's no session
    # renegotiation or liveness probe needed on checkout.
    {:ok, state}
  end

  @impl true
  def ping(state) do
    case Connection.ping(state) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        {:disconnect, connection_error("ping failed", reason), state}
    end
  end

  @impl true
  def handle_execute(%Query{statement: statement} = query, _params, opts, state) do
    case Connection.query(state, statement, opts) do
      {:ok, %{columns: columns, rows: rows}} ->
        result = %Result{columns: columns, rows: rows, num_rows: length(rows)}
        {:ok, query, result, state}

      {:error, %ChDriver.Error{} = error} ->
        # A well-formed Exception packet from the server -- the socket
        # itself is still in a valid, reusable state (query/2 only returns
        # this after fully consuming the response stream up to
        # EndOfStream-equivalent), so this is a normal query error, not a
        # connection failure.
        {:error, error, state}

      {:error, reason} when reason in [:closed, :timeout] ->
        {:disconnect, connection_error("connection lost during query", reason), state}

      {:error, reason} ->
        {:disconnect, connection_error("socket error during query", reason), state}
    end
  end

  @impl true
  def handle_status(_opts, state), do: {:idle, state}

  @impl true
  def handle_begin(_opts, state) do
    {:error, not_supported("transactions"), state}
  end

  @impl true
  def handle_commit(_opts, state) do
    {:error, not_supported("transactions"), state}
  end

  @impl true
  def handle_rollback(_opts, state) do
    {:error, not_supported("transactions"), state}
  end

  @impl true
  def handle_prepare(query, _opts, state), do: {:ok, query, state}

  @impl true
  def handle_close(_query, _opts, state) do
    {:ok, %Result{}, state}
  end

  @impl true
  def handle_declare(_query, _params, _opts, state) do
    {:error, not_supported("cursors"), state}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, state) do
    {:error, not_supported("cursors"), state}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:error, not_supported("cursors"), state}
  end

  defp not_supported(feature) do
    connection_error("#{feature} are not supported by ChDriver.DBConnection", :not_supported)
  end

  defp connection_error(message, reason) do
    ConnectionError.exception("#{message}: #{inspect(reason)}", :error)
  end
end
