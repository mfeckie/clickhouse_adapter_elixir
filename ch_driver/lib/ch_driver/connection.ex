defmodule ChDriver.Connection do
  @moduledoc """
  Opens a TCP connection to ClickHouse and runs queries over it.

  This is the low-level connection API that `ChDriver.DBConnection` wraps
  to plug into `DBConnection`'s pooling. You'd only call it directly if
  you're managing a single raw connection yourself.

  * `connect/1` opens the socket and performs the Hello handshake.
  * `query/3` runs a query to completion and returns the full result.
  * `start_stream/3`, `stream_fetch/2`, and `cancel_stream/2` run a query
    and read its result back one block at a time instead of all at once.
  * `ping/1` checks the connection is alive.

  Packet encoding/decoding itself lives in `ChDriver.Protocol`; this module
  owns the socket, buffering incoming bytes, and looping over the response
  packets a query produces.
  """

  alias ChDriver.Protocol

  @default_port 9000
  @default_connect_timeout 5_000
  @default_recv_timeout 5_000

  # Client-side ceiling on how large the accumulated receive buffer is
  # allowed to grow while waiting for more bytes from the server, mirroring
  # Postgrex's `@max_packet` (see `postgrex/lib/postgrex/protocol.ex`). A
  # corrupted/malicious server or a client-side protocol desync can produce
  # a garbled length-prefix varint (e.g. a column's declared string length,
  # or a block's declared row/column count) that the decoders below would
  # otherwise wait on forever, accumulating bytes from every subsequent
  # `:gen_tcp.recv/3` call into an ever-growing buffer -- only ever bounded
  # by `recv_timeout`, by which point the process may already hold an
  # enormous binary. 64MB matches Postgrex's own default.
  @default_max_buffer_size 64 * 1024 * 1024

  @doc """
  Opens a TCP connection to a ClickHouse server and performs the Hello
  handshake.

  ## Options

    * `:hostname` - defaults to `~c"localhost"`
    * `:port` - defaults to `9000`
    * `:database` - default_database to advertise, defaults to `"default"`
    * `:username` - defaults to `"default"`
    * `:password` - defaults to `""`
    * `:connect_timeout` - TCP connect timeout in ms, defaults to `5_000`
    * `:recv_timeout` - `:gen_tcp.recv/3` timeout in ms, defaults to `5_000`
    * `:max_buffer_size` - maximum accumulated receive-buffer size in bytes
      before the handshake fails fast with `{:error, %ChDriver.Error{}}`
      instead of growing the buffer without limit, defaults to
      `#{@default_max_buffer_size}` (64MB)
    * `:compression` - `:none` (default) or `:lz4`. Turns on wire
      compression for this connection's query result blocks. Acts as a
      per-connection default; `query/3`'s own `opts` can override it per
      call. Any other value raises `ArgumentError`.

  Returns `{:ok, %{socket: socket, server_info: %ChDriver.Protocol.ServerHello{}, compression: :none | :lz4}}`
  on success, or `{:error, reason}` on failure. The caller owns the
  returned socket and is responsible for closing it with `close/1`.
  """
  @spec connect(keyword) ::
          {:ok,
           %{
             socket: :gen_tcp.socket(),
             server_info: Protocol.ServerHello.t(),
             compression: ChDriver.Protocol.Block.Compressed.method()
           }}
          | {:error, term}
  def connect(opts \\ []) do
    hostname = opts |> Keyword.get(:hostname, "localhost") |> to_charlist()
    port = Keyword.get(opts, :port, @default_port)
    database = Keyword.get(opts, :database, "default")
    username = Keyword.get(opts, :username, "default")
    password = Keyword.get(opts, :password, "")
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
    compression = validate_compression!(Keyword.get(opts, :compression, :none))

    tcp_opts = [:binary, packet: :raw, active: false]

    case :gen_tcp.connect(hostname, port, tcp_opts, connect_timeout) do
      {:ok, socket} ->
        do_handshake(
          socket,
          database,
          username,
          password,
          recv_timeout,
          max_buffer_size,
          compression
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_compression!(compression) when compression in [:none, :lz4], do: compression

  defp validate_compression!(other) do
    raise ArgumentError,
          "invalid :compression option #{inspect(other)} -- must be :none or :lz4"
  end

  # Performs the Hello/Addendum handshake on an already-open socket. If any
  # step fails partway through, the socket must be closed here -- the
  # caller never receives it (connect/1 only returns a socket on full
  # success), so nothing else would ever close it otherwise, leaking an open
  # :gen_tcp socket on every partial-handshake failure (bad credentials,
  # unexpected/garbled ServerHello, a mid-handshake network drop, etc).
  defp do_handshake(
         socket,
         database,
         username,
         password,
         recv_timeout,
         max_buffer_size,
         compression
       ) do
    hello = Protocol.client_hello(database, username, password)

    with :ok <- :gen_tcp.send(socket, Protocol.encode_client_hello(hello)),
         {:ok, server_info} <-
           receive_server_hello(socket, <<>>, recv_timeout, max_buffer_size),
         :ok <- send_addendum_if_required(socket) do
      {:ok, %{socket: socket, server_info: server_info, compression: compression}}
    else
      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  # See `ChDriver.Protocol.Messages.encode_addendum/0` for the full
  # explanation of what the Addendum is, when it's required, and why
  # skipping it silently desyncs every subsequent byte on the connection.
  defp send_addendum_if_required(socket) do
    if Protocol.addendum_required?() do
      :gen_tcp.send(socket, Protocol.encode_addendum())
    else
      :ok
    end
  end

  @doc """
  Closes a socket previously returned by `connect/1`.
  """
  @spec close(:gen_tcp.socket()) :: :ok
  def close(socket) do
    :gen_tcp.close(socket)
  end

  defp receive_server_hello(socket, buffer, timeout, max_buffer_size) do
    case Protocol.decode_server_hello(buffer) do
      {:ok, server_info, _rest} ->
        {:ok, server_info}

      {:incomplete, _} ->
        with :ok <- check_buffer_size(buffer, max_buffer_size),
             {:ok, more} <- :gen_tcp.recv(socket, 0, timeout) do
          receive_server_hello(socket, buffer <> more, timeout, max_buffer_size)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs `query_string` against the connection returned by `connect/1` and
  collects the full result.

  `opts[:params]` binds `query_string`'s `{name:Type}` placeholders — a list
  of `{name, raw_text}` or `{name, raw_text, escape_rounds}` tuples (see
  `ChDriver.Params.text/1` and `ChDriver.Params.escape_rounds/1` for
  building these from Elixir values).

  `opts[:compression]` (`:none` or `:lz4`) overrides the connection's
  default compression setting for this one query.

  Returns `{:ok, %{columns: [{name, type}], rows: [[term]]}}` or
  `{:error, term}` — either a socket error, or a `%ChDriver.Error{}` if
  ClickHouse rejected the query.
  """
  @spec query(map, binary, keyword) :: {:ok, map} | {:error, term}
  def query(%{socket: socket} = conn, query_string, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
    compression = Keyword.get(opts, :compression, Map.get(conn, :compression, :none))

    packet = [
      Protocol.encode_query(query_string, Keyword.put(opts, :compression, compression)),
      Protocol.encode_empty_data_packet(compression)
    ]

    with :ok <- :gen_tcp.send(socket, packet) do
      socket
      |> receive_query_result(
        <<>>,
        recv_timeout,
        %{columns: nil, rows: []},
        max_buffer_size,
        compression
      )
      |> put_statement(query_string)
    end
  end

  # Stamps the originating SQL text onto a `%ChDriver.Error{}` returned from
  # an Exception packet so callers can correlate the error with the query
  # that triggered it -- ClickHouse's own exception message doesn't always
  # quote the failing SQL (e.g. execution-time type-conversion errors).
  defp put_statement({:error, %ChDriver.Error{} = error}, query_string) do
    {:error, %{error | statement: query_string}}
  end

  defp put_statement(result, _query_string), do: result

  defp receive_query_result(socket, buffer, timeout, acc, max_buffer_size, compression) do
    case Protocol.decode_packet(buffer, compression) do
      {:ok, {:data, %{columns: columns, rows: rows}}, rest} ->
        acc = accumulate_data(acc, columns, rows)
        receive_query_result(socket, rest, timeout, acc, max_buffer_size, compression)

      {:ok, {:profile_events, _block}, rest} ->
        receive_query_result(socket, rest, timeout, acc, max_buffer_size, compression)

      {:ok, {:progress, _progress}, rest} ->
        receive_query_result(socket, rest, timeout, acc, max_buffer_size, compression)

      {:ok, {:profile_info, _profile_info}, rest} ->
        receive_query_result(socket, rest, timeout, acc, max_buffer_size, compression)

      {:ok, :pong, rest} ->
        receive_query_result(socket, rest, timeout, acc, max_buffer_size, compression)

      {:ok, :end_of_stream, _rest} ->
        {:ok, %{columns: acc.columns || [], rows: Enum.reverse(acc.rows)}}

      {:ok, {:exception, error}, _rest} ->
        {:error, error}

      {:incomplete, _} ->
        with :ok <- check_buffer_size(buffer, max_buffer_size),
             {:ok, more} <- :gen_tcp.recv(socket, 0, timeout) do
          receive_query_result(socket, buffer <> more, timeout, acc, max_buffer_size, compression)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Guards against unbounded buffer growth: a garbled length-prefix varint
  # (a column's declared string length, a block's row/column count, ...)
  # can make a decoder return `:incomplete` forever, since the byte count
  # it's actually waiting for never arrives. Without this check, the
  # receive loops above would keep calling `:gen_tcp.recv/3` and
  # concatenating the result onto `buffer` indefinitely, only ever bounded
  # by `recv_timeout` -- by which point the process may already hold an
  # enormous binary. Checked *before* issuing another `recv` so a single
  # oversized/garbled response already sitting in the socket's receive
  # buffer fails immediately, without waiting on the network at all.
  defp check_buffer_size(buffer, max_buffer_size) do
    size = byte_size(buffer)

    if size > max_buffer_size do
      {:error,
       %ChDriver.Error{
         name: "ChDriver::MaxBufferSizeExceeded",
         message:
           "receive buffer grew to #{size} bytes, exceeding the #{max_buffer_size}-byte " <>
             "max_buffer_size -- failing fast instead of continuing to buffer an " <>
             "incomplete/corrupted response (see :max_buffer_size option)"
       }}
    else
      :ok
    end
  end

  # ClickHouse sends an empty "header" Data block (0 rows, but with the
  # result's column names/types) before any Data block with actual rows.
  # Keep the first non-empty column list we see; accumulate rows from every
  # Data block (in order) regardless of how many blocks the result spans.
  defp accumulate_data(%{columns: nil} = acc, columns, rows) do
    %{acc | columns: columns, rows: Enum.reverse(rows, acc.rows)}
  end

  defp accumulate_data(acc, _columns, rows) do
    %{acc | rows: Enum.reverse(rows, acc.rows)}
  end

  @doc """
  Starts running `query_string` for block-at-a-time streaming, instead of
  reading the whole result the way `query/3` does.

  Sends the query and reads just far enough to know the result's column
  names/types, then returns a stream handle that `stream_fetch/2` reads
  further blocks from on demand.

  Returns `{:ok, stream}` or `{:error, reason}` (a socket error or a
  `%ChDriver.Error{}`, exactly like `query/3`). `stream` is opaque — pass
  it straight to `stream_fetch/2` and `cancel_stream/2`.
  """
  @spec start_stream(map, binary, keyword) :: {:ok, map} | {:error, term}
  def start_stream(%{socket: socket} = conn, query_string, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
    compression = Keyword.get(opts, :compression, Map.get(conn, :compression, :none))

    packet = [
      Protocol.encode_query(query_string, Keyword.put(opts, :compression, compression)),
      Protocol.encode_empty_data_packet(compression)
    ]

    with :ok <- :gen_tcp.send(socket, packet) do
      socket
      |> receive_first_nonempty_block(<<>>, recv_timeout, max_buffer_size, compression, nil)
      |> build_stream(recv_timeout, max_buffer_size, compression)
      |> put_statement(query_string)
    end
  end

  # ClickHouse always sends an empty "header" Data block (0 rows, columns
  # only) before any block with actual rows (see `accumulate_data/3`
  # above) -- skip it (and, defensively, any further 0-row `:cont` block,
  # in case a server/version ever sends more than one) so `start_stream/3`
  # never surfaces a content-free block as if it were real stream data.
  # A `:cont` block that already carries rows (or `:halt`, meaning the
  # query genuinely returned nothing) is returned as-is and stashed as
  # `stream.pending` by `build_stream/4` for the first `stream_fetch/2`
  # call to hand back without any further socket I/O.
  defp receive_first_nonempty_block(
         socket,
         buffer,
         timeout,
         max_buffer_size,
         compression,
         columns
       ) do
    case receive_stream_block(socket, buffer, timeout, max_buffer_size, compression, columns) do
      {:cont, %{rows: []}, rest, columns} ->
        receive_first_nonempty_block(socket, rest, timeout, max_buffer_size, compression, columns)

      other ->
        other
    end
  end

  defp build_stream({:cont, block, buffer, columns}, recv_timeout, max_buffer_size, compression) do
    {:ok,
     %{
       columns: columns,
       buffer: buffer,
       recv_timeout: recv_timeout,
       max_buffer_size: max_buffer_size,
       compression: compression,
       pending: {:cont, block.rows},
       done: false
     }}
  end

  defp build_stream({:halt, block, buffer, columns}, recv_timeout, max_buffer_size, compression) do
    {:ok,
     %{
       columns: columns,
       buffer: buffer,
       recv_timeout: recv_timeout,
       max_buffer_size: max_buffer_size,
       compression: compression,
       pending: {:halt, block.rows},
       done: true
     }}
  end

  defp build_stream({:error, reason}, _recv_timeout, _max_buffer_size, _compression) do
    {:error, reason}
  end

  @doc """
  Fetches the next block of a stream started by `start_stream/3`.

  Returns `{:cont, %{columns:, rows:}, stream}` while more blocks remain,
  `{:halt, %{columns:, rows:}, stream}` once the result is exhausted (every
  further call then returns the same empty `:halt` immediately), or
  `{:error, reason}`.
  """
  @spec stream_fetch(:gen_tcp.socket(), map) :: {:cont | :halt, map, map} | {:error, term}
  def stream_fetch(_socket, %{pending: {status, rows}} = stream) do
    block = %{columns: stream.columns, rows: rows}
    {status, block, %{stream | pending: nil, done: status == :halt}}
  end

  def stream_fetch(_socket, %{done: true} = stream) do
    {:halt, %{columns: stream.columns, rows: []}, stream}
  end

  def stream_fetch(socket, stream) do
    %{
      buffer: buffer,
      recv_timeout: timeout,
      max_buffer_size: max_buffer_size,
      compression: compression,
      columns: columns
    } = stream

    case receive_stream_block(socket, buffer, timeout, max_buffer_size, compression, columns) do
      {:cont, block, rest, columns} ->
        {:cont, block, %{stream | buffer: rest, columns: columns}}

      {:halt, block, rest, columns} ->
        {:halt, block, %{stream | buffer: rest, columns: columns, done: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a stream started by `start_stream/3` and leaves the connection
  ready for the next query.

  If the stream already ran to completion, this is a no-op. Otherwise
  (e.g. the caller did `Enum.take/2` on a large stream and stopped early)
  it tells ClickHouse to cancel the query and drains any blocks still in
  flight, so the socket ends up in a clean state for whatever query you
  run next.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec cancel_stream(:gen_tcp.socket(), map) :: :ok | {:error, term}
  def cancel_stream(_socket, %{done: true}), do: :ok

  def cancel_stream(socket, %{
        buffer: buffer,
        recv_timeout: timeout,
        max_buffer_size: max_buffer_size,
        compression: compression,
        columns: columns
      }) do
    with :ok <- :gen_tcp.send(socket, Protocol.encode_cancel()) do
      drain_stream(socket, buffer, timeout, max_buffer_size, compression, columns)
    end
  end

  defp drain_stream(socket, buffer, timeout, max_buffer_size, compression, columns) do
    case receive_stream_block(socket, buffer, timeout, max_buffer_size, compression, columns) do
      {:cont, _block, rest, columns} ->
        drain_stream(socket, rest, timeout, max_buffer_size, compression, columns)

      {:halt, _block, _rest, _columns} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The pausable sibling of `receive_query_result/6` above: rather than
  # looping until `:end_of_stream` and accumulating every Data block seen
  # into `acc`, this returns as soon as it has decoded exactly one
  # Data/end-of-stream/exception packet, handing back enough state
  # (`rest`, the unconsumed buffer tail, and `columns`, the
  # first-non-nil-seen column list, mirroring `accumulate_data/3`'s own
  # "keep the first non-nil columns" rule) for the caller to resume from
  # later. `columns` starts as `nil` (from `start_stream/3`) and is
  # threaded through unchanged by every subsequent `stream_fetch/2` call,
  # so a Data block's own possibly-empty column list is never mistaken
  # for "no columns" once real ones are known.
  defp receive_stream_block(socket, buffer, timeout, max_buffer_size, compression, columns) do
    case Protocol.decode_packet(buffer, compression) do
      {:ok, {:data, %{columns: block_columns, rows: rows}}, rest} ->
        resolved = columns || block_columns
        {:cont, %{columns: resolved, rows: rows}, rest, resolved}

      {:ok, {:profile_events, _block}, rest} ->
        receive_stream_block(socket, rest, timeout, max_buffer_size, compression, columns)

      {:ok, {:progress, _progress}, rest} ->
        receive_stream_block(socket, rest, timeout, max_buffer_size, compression, columns)

      {:ok, {:profile_info, _profile_info}, rest} ->
        receive_stream_block(socket, rest, timeout, max_buffer_size, compression, columns)

      {:ok, :pong, rest} ->
        receive_stream_block(socket, rest, timeout, max_buffer_size, compression, columns)

      {:ok, :end_of_stream, rest} ->
        {:halt, %{columns: columns || [], rows: []}, rest, columns}

      {:ok, {:exception, error}, _rest} ->
        {:error, error}

      {:incomplete, _} ->
        with :ok <- check_buffer_size(buffer, max_buffer_size),
             {:ok, more} <- :gen_tcp.recv(socket, 0, timeout) do
          receive_stream_block(
            socket,
            buffer <> more,
            timeout,
            max_buffer_size,
            compression,
            columns
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a Ping packet and waits for the server's Pong. Returns `:ok` on a
  successful round-trip or `{:error, term}` on a socket error or an
  unexpected response.
  """
  @spec ping(map, keyword) :: :ok | {:error, term}
  def ping(%{socket: socket}, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)

    with :ok <- :gen_tcp.send(socket, Protocol.encode_ping()) do
      receive_pong(socket, <<>>, recv_timeout, max_buffer_size)
    end
  end

  defp receive_pong(socket, buffer, timeout, max_buffer_size) do
    case Protocol.decode_packet(buffer) do
      {:ok, :pong, _rest} ->
        :ok

      {:ok, other, _rest} ->
        {:error, {:unexpected_ping_response, other}}

      {:incomplete, _} ->
        with :ok <- check_buffer_size(buffer, max_buffer_size),
             {:ok, more} <- :gen_tcp.recv(socket, 0, timeout) do
          receive_pong(socket, buffer <> more, timeout, max_buffer_size)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
