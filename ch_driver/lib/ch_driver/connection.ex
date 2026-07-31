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

  Returns `{:ok, %{socket: socket, server_info: %ChDriver.Protocol.ServerHello{}}}`
  on success, or `{:error, reason}` on failure. The caller owns the
  returned socket and is responsible for closing it (see
  `ChDriver.Connection.close/1`).
  """
  @spec connect(keyword) ::
          {:ok, %{socket: :gen_tcp.socket(), server_info: Protocol.ServerHello.t()}}
          | {:error, term}
  def connect(opts \\ []) do
    hostname = opts |> Keyword.get(:hostname, "localhost") |> to_charlist()
    port = Keyword.get(opts, :port, @default_port)
    database = Keyword.get(opts, :database, "default")
    username = Keyword.get(opts, :username, "default")
    password = Keyword.get(opts, :password, "")
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)

    tcp_opts = [:binary, packet: :raw, active: false]

    case :gen_tcp.connect(hostname, port, tcp_opts, connect_timeout) do
      {:ok, socket} ->
        do_handshake(socket, database, username, password, recv_timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Performs the Hello/Addendum handshake on an already-open socket. If any
  # step fails partway through, the socket must be closed here -- the
  # caller never receives it (connect/1 only returns a socket on full
  # success), so nothing else would ever close it otherwise, leaking an open
  # :gen_tcp socket on every partial-handshake failure (bad credentials,
  # unexpected/garbled ServerHello, a mid-handshake network drop, etc).
  defp do_handshake(socket, database, username, password, recv_timeout) do
    hello = Protocol.client_hello(database, username, password)

    with :ok <- :gen_tcp.send(socket, Protocol.encode_client_hello(hello)),
         {:ok, server_info} <- receive_server_hello(socket, <<>>, recv_timeout),
         :ok <- send_addendum_if_required(socket) do
      {:ok, %{socket: socket, server_info: server_info}}
    else
      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  # CRITICAL: ClickHouse requires this immediately after ServerHello, before
  # any Query packet, whenever the client's advertised revision is >=
  # DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM (54458) -- which this driver's
  # fixed revision always is. It's a raw length-prefixed string (empty
  # quota key), *not* a full packet (no packet-type varint). Skipping this
  # silently desyncs every subsequent byte: the server blocks on it right
  # after sending ServerHello, so it consumes the start of whatever we send
  # next (e.g. a Query packet) as this string instead, surfacing later as a
  # confusing, seemingly-unrelated protocol error. See
  # `ChDriver.Protocol.addendum_required?/0` for how this was found live.
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

  defp receive_server_hello(socket, buffer, timeout) do
    case Protocol.decode_server_hello(buffer) do
      {:ok, server_info, _rest} ->
        {:ok, server_info}

      {:incomplete, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more} -> receive_server_hello(socket, buffer <> more, timeout)
          {:error, reason} -> {:error, reason}
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

  Returns `{:ok, %{columns: [{name, type}], rows: [[term]]}}` or
  `{:error, term}` (either a socket error or a `%ChDriver.Error{}`).
  """
  @spec query(map, binary, keyword) :: {:ok, map} | {:error, term}
  def query(%{socket: socket}, query_string, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)

    packet = [
      Protocol.encode_query(query_string, opts),
      Protocol.encode_empty_data_packet()
    ]

    with :ok <- :gen_tcp.send(socket, packet) do
      receive_query_result(socket, <<>>, recv_timeout, %{columns: nil, rows: []})
    end
  end

  defp receive_query_result(socket, buffer, timeout, acc) do
    case Protocol.decode_packet(buffer) do
      {:ok, {:data, %{columns: columns, rows: rows}}, rest} ->
        acc = accumulate_data(acc, columns, rows)
        receive_query_result(socket, rest, timeout, acc)

      {:ok, {:profile_events, _block}, rest} ->
        receive_query_result(socket, rest, timeout, acc)

      {:ok, {:progress, _progress}, rest} ->
        receive_query_result(socket, rest, timeout, acc)

      {:ok, {:profile_info, _profile_info}, rest} ->
        receive_query_result(socket, rest, timeout, acc)

      {:ok, :pong, rest} ->
        receive_query_result(socket, rest, timeout, acc)

      {:ok, :end_of_stream, _rest} ->
        {:ok, %{columns: acc.columns || [], rows: Enum.reverse(acc.rows)}}

      {:ok, {:exception, error}, _rest} ->
        {:error, error}

      {:incomplete, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more} -> receive_query_result(socket, buffer <> more, timeout, acc)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
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
  Sends a Ping packet and waits for the server's Pong. Returns `:ok` on a
  successful round-trip or `{:error, term}` on a socket error or an
  unexpected response.
  """
  @spec ping(map, keyword) :: :ok | {:error, term}
  def ping(%{socket: socket}, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)

    with :ok <- :gen_tcp.send(socket, Protocol.encode_ping()) do
      receive_pong(socket, <<>>, recv_timeout)
    end
  end

  defp receive_pong(socket, buffer, timeout) do
    case Protocol.decode_packet(buffer) do
      {:ok, :pong, _rest} ->
        :ok

      {:ok, other, _rest} ->
        {:error, {:unexpected_ping_response, other}}

      {:incomplete, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more} -> receive_pong(socket, buffer <> more, timeout)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
