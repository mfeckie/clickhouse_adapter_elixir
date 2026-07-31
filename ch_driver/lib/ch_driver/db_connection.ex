defmodule ChDriver.DBConnection do
  @moduledoc """
  `DBConnection` behaviour implementation wrapping `ChDriver.Connection`'s
  synchronous request/response socket so it can be used as a normal pooled
  connection.

  ClickHouse's native TCP protocol is a plain, unpipelined request/response
  protocol -- one query in flight per socket at a time -- so this module is
  a thin adapter: `handle_execute/4` receives `query` (a `%ChDriver.Query{}`
  already lexed once by `DBConnection.Query.parse/2`) and `encoded_params`
  (this call's values, already run through `DBConnection.Query.encode/3`),
  splices them together into the final wire statement + `{name, raw_text,
  escape_rounds}` params via `ChDriver.Query.to_wire/2`, calls
  `ChDriver.Connection.query/2,3`, and translates its
  `{:ok, %{columns:, rows:}}` / `{:error, term}` shape into DBConnection's
  `{:ok, query, result, state}` / `{:error | :disconnect, exception, state}`
  contract -- `result` here is the raw `{columns, rows}` map;
  `DBConnection.Query.decode/3` (in `ch_driver/lib/ch_driver/query.ex`) is
  what turns it into a `%ChDriver.Result{}`, so it can honor
  `opts[:decode_mapper]`.

  Socket-level failures (`:gen_tcp` errors such as `:closed`/`:timeout`)
  are treated as `:disconnect` so the pool tears down and reconnects the
  underlying socket; ClickHouse-level query errors (a decoded
  `%ChDriver.Error{}` from an Exception packet) are returned as ordinary
  `:error` results, since the connection itself is still perfectly usable
  for the next query.

  There is no transaction support in the ClickHouse native protocol as
  used here, so `handle_begin/2`, `handle_commit/2`, and
  `handle_rollback/2` are unimplemented stubs that error out rather than
  silently pretending to do something; `handle_status/2` always reports
  `:idle` since there is no transaction state to track.

  ## Cursors (`handle_declare/4`, `handle_fetch/4`, `handle_deallocate/4`)

  Unlike transactions, real incremental streaming *is* achievable here:
  ClickHouse's native protocol already delivers a query's result as a
  header block followed by N Data blocks followed by EndOfStream, and
  `ChDriver.Connection.start_stream/3` / `stream_fetch/2` /
  `cancel_stream/2` expose that per-block loop instead of always running
  it to completion and accumulating everything into memory the way
  `handle_execute/4` does. The "cursor" `handle_fetch/4` receives back
  from DBConnection on every call is a fixed value chosen once by
  `handle_declare/4` (a bare `reference/0`, never inspected) --
  DBConnection does *not* thread an updated cursor between fetches (see
  its `@callback handle_fetch/4` docs: it returns `new_state`, not a new
  cursor), so the actual mutable stream position (the unconsumed buffer
  tail, current known columns, whether `:end_of_stream` has been seen)
  has to live in the connection `state` itself, under `state.stream` --
  exactly the socket/buffer persistence this needs, since `state` is
  threaded through every callback the normal way.

  `handle_declare/4` is only reachable with a connection already checked
  out to the calling process for the whole declare/fetch*/deallocate
  sequence (`DBConnection.stream/4`'s own `resource/5` helper requires an
  already-checked-out `%DBConnection{}` -- see `ChDriver.stream/2,3,4`'s
  moduledoc), so there's no risk of a pooled connection handing the
  cursor's socket to a different physical connection mid-stream.
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
