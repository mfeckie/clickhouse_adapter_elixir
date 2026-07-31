defmodule ChDriver.Connection do
  @moduledoc """
  Socket-level connection setup for ClickHouse's native TCP protocol.

  This module only handles opening the TCP socket and performing the
  initial Hello handshake (ClientHello sent, ServerHello parsed). It does
  not implement Query/Data packet handling -- see `ChDriver.Protocol` for
  the Hello packet encode/decode and a later driver layer for query
  execution.
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
      rather than growing the buffer unbounded, defaults to `#{@default_max_buffer_size}`
      (64MB, matching Postgrex's `@max_packet`)
    * `:compression` - `:none` (default) or `:lz4`. Opt-in wire compression
      for `query/3`'s outbound/inbound Data blocks -- off by default so
      existing callers see byte-for-byte unchanged behavior. This is a
      per-connection default; `query/3`'s own `opts` can override it per
      call. See `ChDriver.Protocol.Messages.encode_query/2`'s moduledoc for
      exactly how this is negotiated with the server and why both
      directions of block traffic are affected. The only unsupported value
      besides these two raises `ArgumentError` rather than silently falling
      back to uncompressed.

      KNOWN LIMITATION (tracked as `clickhouse_adapter_elixir-g8o`): decoding
      a real (larger than ~64-byte) compressed Data block currently fails
      with `{:error, :checksum_mismatch}` because `ch_codec`'s `cityhash128/1`
      NIF computes CityHash v1.0.3 instead of the v1.0.2 variant ClickHouse
      actually uses on the wire -- a bug in a dependency, not in this
      negotiation logic (verified: LZ4 compress/decompress themselves are
      unaffected). Tiny results (e.g. `SELECT 1`) happen to round-trip
      anyway, since the two CityHash versions agree below that size. Do not
      enable `:compression` for anything beyond trivial result sets until
      g8o is fixed.

  Returns `{:ok, %{socket: socket, server_info: %ChDriver.Protocol.ServerHello{}, compression: :none | :lz4}}`
  on success, or `{:error, reason}` on failure. The caller owns the
  returned socket and is responsible for closing it (see
  `ChDriver.Connection.close/1`).
  """
  @spec connect(keyword) ::
          {:ok,
           %{
             socket: :gen_tcp.socket(),
             server_info: Protocol.ServerHello.t(),
             compression: ChNative.Block.method()
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
  collects the result.

  Sends a Query packet followed by an empty Data packet (required even for
  plain SELECTs -- see `ChDriver.Protocol.encode_empty_data_packet/0`),
  then loops reading and dispatching response packets. `opts` is forwarded
  to `ChDriver.Protocol.encode_query/2` unchanged, so a `:params` list of
  `{name, raw_text}` or `{name, raw_text, escape_rounds}` tuples binds that
  query's `{name:Type}` placeholders (see `ChDriver.Protocol.param_text/1`
  and `ChDriver.Protocol.escape_rounds/1`).

    * `Data`/`ProfileEvents` packets are accumulated (columns come from the
      first Data packet seen with a non-empty column list -- ClickHouse
      sends an empty "header" block first, then one or more Data blocks
      with actual rows; ProfileEvents blocks are ignored for the returned
      result but decoded/consumed so the wire stays in sync).
    * `Progress` packets are ignored (no streaming/partial-result API yet).
    * `Pong` is ignored (only relevant to `ping/1`, not implemented yet).
    * `EndOfStream` ends the loop successfully.
    * `Exception` ends the loop with `{:error, %ChDriver.Error{}}`.

  `opts[:compression]` (`:none` or `:lz4`) overrides the connection's
  default (the `:compression` passed to `connect/1`, `:none` if that
  wasn't given either) for this one query -- see `connect/1`'s docs and
  `ChDriver.Protocol.Messages.encode_query/2`'s moduledoc for what this
  negotiates with the server.

  Returns `{:ok, %{columns: [{name, type}], rows: [[term]]}}` or
  `{:error, term}` (either a socket error or a `%ChDriver.Error{}`).
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
  Starts `query_string` the same way `query/3` does (Query packet + empty
  Data packet), but instead of looping internally to `:end_of_stream` and
  accumulating every row into memory, stops after receiving just one
  block's worth of response -- ClickHouse's own "header" block (0 rows,
  but with the result's column names/types) -- and returns a small,
  stateful "stream" map that `stream_fetch/2` resumes from on demand.

  This is what `ChDriver.DBConnection.handle_declare/4` calls: the
  returned map (`%{columns:, buffer:, done:, recv_timeout:,
  max_buffer_size:, compression:, pending:}`) is exactly the "cursor"
  state that needs to persist across `handle_fetch/4` calls -- the
  socket itself is `conn.socket` (unchanged, owned by the connection the
  whole time), `buffer` is the unconsumed tail of whatever was already
  read off it, and `pending` holds the header block's own rows (almost
  always `[]`, but a tiny result can in principle arrive combined with
  the header in a single block -- see the moduledoc note on
  `receive_stream_block/6` -- so this is never silently dropped) for the
  first `stream_fetch/2` call to hand back without doing any socket I/O.

  Returns `{:ok, stream}` or `{:error, reason}` (a socket error or a
  `%ChDriver.Error{}`, exactly like `query/3`).
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
  Resumes a stream previously started by `start_stream/3` (or a prior
  call to this function), returning exactly one Data block's worth of
  rows -- the natural unit the wire protocol already delivers, so there's
  no artificial row-count-based rebatching here.

  If `stream.pending` is set (the header block's own rows, stashed by
  `start_stream/3` and not yet handed back), returns that directly
  without touching the socket at all. Otherwise resumes the receive loop
  from `stream.buffer` on `socket`.

  Returns `{:cont, %{columns:, rows:}, stream}` while more blocks remain,
  `{:halt, %{columns:, rows:}, stream}` once `:end_of_stream` is reached
  (`stream.done` is `true` from then on, and every further call returns
  the same empty `:halt` immediately), or `{:error, reason}`.
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
  Cleans up a stream previously started by `start_stream/3`, for
  `ChDriver.DBConnection.handle_deallocate/4`.

  If the stream already reached `:end_of_stream` (`stream.done` is
  `true` -- the caller consumed every block via `stream_fetch/2`), there
  is nothing left in flight and this is a no-op returning `:ok`
  immediately.

  Otherwise (the caller stopped early, e.g. `Enum.take/2` on a partially
  consumed stream) there is no server-side portal/cursor to close the
  way Postgres has -- but ClickHouse's native protocol does have a
  Cancel packet (Client packet type 3): this sends it, then keeps
  draining and discarding blocks off the same socket/buffer until
  `:end_of_stream` (blocks already in flight before the server notices
  the cancellation can still arrive), so the connection is left in a
  clean, byte-position-correct state for the next query instead of
  leaking unread bytes that would desync the very next request sent on
  this socket.

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
