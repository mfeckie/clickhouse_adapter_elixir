defmodule ChDriver.DBConnection do
  @moduledoc """
  `DBConnection` behaviour implementation for ClickHouse's native TCP
  protocol.

  This is internal wiring: it's what makes `ChDriver.start_link/1` and
  `ChDriver.query/2,3,4` work as a normal pooled connection, but you should
  never call functions in this module directly. Use `ChDriver`'s public API
  instead.

  ClickHouse's native protocol is unpipelined request/response — one query
  in flight per socket at a time — so this module is a thin adapter over
  `ChDriver.Connection`: `handle_execute/4` builds the final wire statement
  and params, runs the query, and translates the result into the shape
  `DBConnection` expects.

  Socket-level failures disconnect the pooled connection so it gets torn
  down and reconnected; a ClickHouse-level query error (a rejected query,
  a syntax error, etc.) is returned as an ordinary error instead, since the
  connection itself is still fine to reuse.

  There's no transaction support in ClickHouse's native protocol, so
  `handle_begin/2`, `handle_commit/2`, and `handle_rollback/2` all return an
  error rather than pretending to do something.

  ## Cursors

  `handle_declare/4`, `handle_fetch/4`, and `handle_deallocate/4` back
  `ChDriver.stream/2,3,4`: they read a query's result one block at a time
  via `ChDriver.Connection.start_stream/3` / `stream_fetch/2` /
  `cancel_stream/2`, instead of accumulating the whole thing into memory
  the way `handle_execute/4` does.
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
        {:ok,
         %{
           socket: conn.socket,
           server_info: conn.server_info,
           compression: conn.compression,
           settings: conn.settings,
           opts: opts
         }}

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
  def handle_execute(%Query{} = query, encoded_params, opts, state) do
    {statement, wire_params} = Query.to_wire(query, encoded_params)
    opts = Keyword.put(opts, :params, wire_params)

    case Connection.query(state, statement, opts) do
      {:ok, %{columns: _columns, rows: _rows} = result} ->
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
  def handle_declare(%Query{} = query, params, opts, state) do
    {statement, wire_params} = Query.to_wire(query, params)
    opts = Keyword.put(opts, :params, wire_params)

    case Connection.start_stream(state, statement, opts) do
      {:ok, stream} ->
        cursor = make_ref()
        {:ok, query, cursor, Map.put(state, :stream, stream)}

      {:error, %ChDriver.Error{} = error} ->
        {:error, error, state}

      {:error, reason} when reason in [:closed, :timeout] ->
        {:disconnect, connection_error("connection lost during declare", reason), state}

      {:error, reason} ->
        {:disconnect, connection_error("socket error during declare", reason), state}
    end
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, %{stream: stream, socket: socket} = state) do
    case Connection.stream_fetch(socket, stream) do
      {:cont, block, new_stream} ->
        {:cont, block, %{state | stream: new_stream}}

      {:halt, block, new_stream} ->
        {:halt, block, %{state | stream: new_stream}}

      {:error, %ChDriver.Error{} = error} ->
        {:error, error, Map.delete(state, :stream)}

      {:error, reason} when reason in [:closed, :timeout] ->
        {:disconnect, connection_error("connection lost during fetch", reason), state}

      {:error, reason} ->
        {:disconnect, connection_error("socket error during fetch", reason), state}
    end
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, %{stream: nil} = state) do
    {:ok, %Result{}, state}
  end

  def handle_deallocate(_query, _cursor, _opts, %{stream: stream, socket: socket} = state)
      when is_map(stream) do
    case Connection.cancel_stream(socket, stream) do
      :ok ->
        {:ok, %Result{}, Map.delete(state, :stream)}

      {:error, %ChDriver.Error{}} ->
        # A well-formed Exception packet arrived while draining -- the
        # socket itself is still byte-position-correct (drain_stream/6
        # only returns this after decoding a full packet, not mid-packet),
        # so the connection is still reusable for the next query.
        {:ok, %Result{}, Map.delete(state, :stream)}

      {:error, reason} when reason in [:closed, :timeout] ->
        {:disconnect, connection_error("connection lost during deallocate", reason),
         Map.delete(state, :stream)}

      {:error, reason} ->
        {:disconnect, connection_error("socket error during deallocate", reason),
         Map.delete(state, :stream)}
    end
  end

  def handle_deallocate(_query, _cursor, _opts, state) do
    {:ok, %Result{}, Map.delete(state, :stream)}
  end

  defp not_supported(feature) do
    connection_error("#{feature} are not supported by ChDriver.DBConnection", :not_supported)
  end

  defp connection_error(message, reason) do
    ConnectionError.exception("#{message}: #{inspect(reason)}", :error)
  end
end
