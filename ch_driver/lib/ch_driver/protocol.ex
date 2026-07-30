defmodule ChDriver.Protocol do
  @moduledoc """
  ClickHouse native-protocol packet types relevant to the initial
  connection handshake.

  The Hello exchange (ClientHello sent, ServerHello received) happens in
  plaintext -- unlike Query/Data packets, it is never wrapped in a
  `ChNative.Block` compressed envelope. Confirmed live against ClickHouse
  24.8 on `:9000`.
  """

  alias ChDriver.Protocol.Varint
  alias ChDriver.Error

  # Packet type discriminants (varint-encoded). Client and server each have
  # their own enum -- see ClickHouse's Protocol.h (Protocol::Client::Enum /
  # Protocol::Server::Enum). Confirmed live against ClickHouse 24.8 (used
  # protocol revision 54469) by capturing real `clickhouse-client` traffic
  # through a local TCP proxy and cross-referencing ClickHouse's own source
  # at tag v24.8.14.39-lts.
  @packet_hello 0

  @client_query 1
  @client_data 2
  @client_ping 4

  @server_data 1
  @server_exception 2
  @server_progress 3
  @server_pong 4
  @server_end_of_stream 5
  @server_profile_info 6
  # ProfileEvents (14) is wire-identical to Data (table name + a Native
  # block) -- see Connection::receiveProfileEvents/receiveDataImpl in
  # ClickHouse's Client/Connection.cpp. We decode it the same way as Data
  # and let callers ignore/inspect it as they see fit.
  @server_profile_events 14

  # Revision this driver advertises to the server. ClickHouse gates several
  # optional ServerHello fields (timezone, display name, version patch) on
  # the negotiated revision -- see DBMS_MIN_REVISION_WITH_* constants in
  # Core/ProtocolDefines.h. 54465 is well above all of them, so a real
  # server always sends the full ServerHello shape below when we advertise
  # this revision. Verified live against ClickHouse 24.8.
  @client_revision 54_465
  @client_version_major 24
  @client_version_minor 8
  @client_version_patch 0
  @client_name "ChDriver"

  @min_revision_with_server_timezone 54_058
  @min_revision_with_server_display_name 54_372
  @min_revision_with_version_patch 54_401

  # DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM (Core/ProtocolDefines.h). Since
  # our advertised @client_revision is always above this, the driver always
  # sends the post-Hello Addendum (currently just an empty quota_key
  # string, no packet-type prefix -- see TCPHandler::receiveAddendum).
  # CRITICAL GAP FOUND LIVE: omitting this step silently desyncs every byte
  # sent afterwards (the server blocks reading it right after ServerHello,
  # so the *next* bytes we send -- e.g. the start of a Query packet -- get
  # consumed as this string instead), which surfaces as a bizarre unrelated
  # "Empty query" (or worse) error from the server despite an
  # otherwise-correct Query packet. Confirmed by diffing our own wire bytes
  # against a real `clickhouse-client` session captured via a TCP proxy.
  @min_revision_with_addendum 54_458

  defmodule ClientHello do
    @moduledoc "The initial packet sent by the client to open a connection."
    defstruct client_name: "ChDriver",
              version_major: 0,
              version_minor: 0,
              version_patch: 0,
              revision: 0,
              default_database: "",
              user: "default",
              password: ""
  end

  defmodule ServerHello do
    @moduledoc "The server's response to ClientHello, describing itself."
    defstruct name: nil,
              version_major: nil,
              version_minor: nil,
              revision: nil,
              timezone: nil,
              display_name: nil,
              version_patch: nil
  end

  @doc """
  Builds a `ClientHello` struct advertising this driver's identity, for the
  given `default_database`, `user`, and `password`.
  """
  @spec client_hello(binary, binary, binary) :: ClientHello.t()
  def client_hello(default_database \\ "default", user \\ "default", password \\ "") do
    %ClientHello{
      client_name: @client_name,
      version_major: @client_version_major,
      version_minor: @client_version_minor,
      version_patch: @client_version_patch,
      revision: @client_revision,
      default_database: default_database,
      user: user,
      password: password
    }
  end

  @doc """
  Encodes a `ClientHello` struct into the plaintext bytes sent to open a
  connection: packet-type varint (0), then client name/version/revision
  and the default_database/user/password length-prefixed strings.
  """
  @spec encode_client_hello(ClientHello.t()) :: iodata
  def encode_client_hello(%ClientHello{} = hello) do
    [
      Varint.encode(@packet_hello),
      Varint.encode_string(hello.client_name),
      Varint.encode(hello.version_major),
      Varint.encode(hello.version_minor),
      Varint.encode(hello.revision),
      Varint.encode_string(hello.default_database),
      Varint.encode_string(hello.user),
      Varint.encode_string(hello.password)
    ]
  end

  @doc """
  Decodes a `ServerHello` packet from the front of `binary`, including its
  leading packet-type varint (expected to be 0).

  Returns `{:ok, %ServerHello{}, rest}`, `{:incomplete, binary}` if more
  bytes are needed, or `{:error, reason}` if the packet type doesn't match
  Hello (e.g. the server sent an Exception instead, most likely due to bad
  credentials).
  """
  @spec decode_server_hello(binary) ::
          {:ok, ServerHello.t(), binary} | {:incomplete, binary} | {:error, term}
  def decode_server_hello(binary) when is_binary(binary) do
    with {:ok, packet_type, rest} <- Varint.decode(binary) do
      if packet_type == @packet_hello do
        decode_server_hello_body(rest)
      else
        {:error, {:unexpected_packet_type, packet_type}}
      end
    else
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  defp decode_server_hello_body(binary) do
    with {:ok, name, rest} <- Varint.decode_string(binary),
         {:ok, version_major, rest} <- Varint.decode(rest),
         {:ok, version_minor, rest} <- Varint.decode(rest),
         {:ok, revision, rest} <- Varint.decode(rest),
         {:ok, timezone, rest} <-
           maybe_decode_string(rest, revision, @min_revision_with_server_timezone),
         {:ok, display_name, rest} <-
           maybe_decode_string(rest, revision, @min_revision_with_server_display_name),
         {:ok, version_patch, rest} <-
           maybe_decode_varint(rest, revision, @min_revision_with_version_patch) do
      server_hello = %ServerHello{
        name: name,
        version_major: version_major,
        version_minor: version_minor,
        revision: revision,
        timezone: timezone,
        display_name: display_name,
        version_patch: version_patch
      }

      {:ok, server_hello, rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_decode_string(binary, revision, min_revision) when revision >= min_revision do
    Varint.decode_string(binary)
  end

  defp maybe_decode_string(binary, _revision, _min_revision) do
    {:ok, nil, binary}
  end

  defp maybe_decode_varint(binary, revision, min_revision) when revision >= min_revision do
    Varint.decode(binary)
  end

  defp maybe_decode_varint(binary, _revision, _min_revision) do
    {:ok, nil, binary}
  end

  @doc """
  Whether this driver's advertised revision requires sending the
  post-ServerHello Addendum (see `encode_addendum/0`). Always `true` for
  `@client_revision`, but exposed so callers gate on the same constant
  the module uses internally.
  """
  @spec addendum_required? :: boolean
  def addendum_required?, do: @client_revision >= @min_revision_with_addendum

  @doc """
  Encodes the Addendum sent immediately after receiving ServerHello, when
  `addendum_required?/0` is true. This is *not* a full packet -- just a raw
  length-prefixed string (the quota key; we always send empty), with no
  leading packet-type varint. See `TCPHandler::receiveAddendum` in
  ClickHouse's Server/TCPHandler.cpp.
  """
  @spec encode_addendum() :: iodata
  def encode_addendum, do: Varint.encode_string("")

  @query_stage_complete 2
  @compression_disabled 0

  @doc """
  Encodes a Query packet (Client packet type 1) for `query_string`.

  Field order (confirmed live against ClickHouse 24.8, revision 54469, by
  capturing real `clickhouse-client` traffic and cross-referencing
  `Connection::sendQuery` / `TCPHandler::receiveQuery` in ClickHouse's own
  source at tag v24.8.14.39-lts):

      packet type (varint, 1)
      query_id (string, empty lets the server generate one)
      ClientInfo (see `encode_client_info/0`)
      per-query settings (string "" -- empty settings list terminator)
      interserver secret (string "" -- gated on
        DBMS_MIN_REVISION_WITH_INTERSERVER_SECRET, always satisfied here)
      query processing stage (varint, 2 = Complete)
      compression (varint, 0 = disabled -- this driver always disables
        compression; Data blocks are then sent/received as plain,
        un-enveloped Native blocks rather than wrapped in
        `ChNative.Block`)
      query string
      query parameters (string "" -- empty terminator, gated on
        DBMS_MIN_PROTOCOL_VERSION_WITH_PARAMETERS, always satisfied here)

  `opts` accepts `:query_id` (defaults to `""`).
  """
  @spec encode_query(binary, keyword) :: iodata
  def encode_query(query_string, opts \\ []) do
    query_id = Keyword.get(opts, :query_id, "")

    [
      Varint.encode(@client_query),
      Varint.encode_string(query_id),
      encode_client_info(),
      Varint.encode_string(""),
      Varint.encode_string(""),
      Varint.encode(@query_stage_complete),
      Varint.encode(@compression_disabled),
      Varint.encode_string(query_string),
      Varint.encode_string("")
    ]
  end

  # ClientInfo sub-structure written as part of a Query packet. Field order
  # confirmed against ClickHouse's Interpreters/ClientInfo.cpp (write/read,
  # tag v24.8.14.39-lts) and live traffic. Every optional field below is
  # gated (in the real source) on a DBMS_MIN_REVISION_WITH_* constant that
  # `@client_revision` (54465) always satisfies, so we always emit them --
  # see the revision table in the moduledoc-adjacent comments above.
  defp encode_client_info do
    query_kind_initial_query = 1
    interface_tcp = 1
    no_opentelemetry_trace = 0

    [
      <<query_kind_initial_query::8>>,
      Varint.encode_string(""),
      Varint.encode_string(""),
      Varint.encode_string("0.0.0.0:0"),
      # initial_query_start_time_microseconds (Int64, native byte order --
      # little-endian on the x86_64/arm64 hosts this targets)
      <<0::little-64>>,
      <<interface_tcp::8>>,
      Varint.encode_string(""),
      Varint.encode_string(""),
      Varint.encode_string(@client_name),
      Varint.encode(@client_version_major),
      Varint.encode(@client_version_minor),
      Varint.encode(@client_revision),
      # quota_key
      Varint.encode_string(""),
      # distributed_depth
      Varint.encode(0),
      # client_version_patch
      Varint.encode(@client_version_patch),
      <<no_opentelemetry_trace::8>>,
      # collaborate_with_initiator, obsolete_count_participating_replicas,
      # number_of_current_replica
      Varint.encode(0),
      Varint.encode(0),
      Varint.encode(0)
    ]
  end

  @doc """
  Encodes an empty Data packet (Client packet type 2): an empty external
  table, sent right after a Query packet to signal "no external tables /
  no input data" (required even for plain SELECTs). The block itself is
  sent as a plain (uncompressed) Native block -- BlockInfo with
  is_overflows=0/bucket_num=-1, zero columns, zero rows -- since this
  driver always negotiates compression=0 in `encode_query/2`.
  """
  @spec encode_empty_data_packet() :: iodata
  def encode_empty_data_packet do
    [
      Varint.encode(@client_data),
      Varint.encode_string(""),
      empty_block_info(),
      Varint.encode(0),
      Varint.encode(0)
    ]
  end

  defp empty_block_info do
    is_overflows_field = 1
    bucket_num_field = 2
    end_of_fields = 0

    [
      Varint.encode(is_overflows_field),
      <<0::8>>,
      Varint.encode(bucket_num_field),
      <<-1::signed-little-32>>,
      Varint.encode(end_of_fields)
    ]
  end

  @doc """
  Encodes a Ping packet (Client packet type 4). No body -- just the
  packet-type varint. Confirmed live against ClickHouse 24.8: the server
  replies with a bare Pong (Server packet type 4, see `@server_pong` /
  `decode_packet/1`) and nothing else.
  """
  @spec encode_ping() :: iodata
  def encode_ping, do: Varint.encode(@client_ping)

  @doc """
  Decodes a single server response packet from the front of `binary`.

  Returns `{:ok, packet, rest}`, `{:incomplete, binary}` if more bytes are
  needed (retry with more buffered data), or `{:error, reason}`.

  `packet` is one of:

    * `{:data, %{table_name:, columns:, rows:}}` -- a Data packet (Server
      packet type 1) or a wire-identical ProfileEvents packet (type 14,
      tagged `:profile_events` instead of `:data`).
    * `{:profile_events, %{table_name:, columns:, rows:}}`
    * `{:progress, %{read_rows:, read_bytes:, total_rows_to_read:,
      total_bytes_to_read:, written_rows:, written_bytes:, elapsed_ns:}}`
    * `:pong`
    * `:end_of_stream`
    * `{:exception, %ChDriver.Error{}}`

  Packet type discriminants and per-type field layouts confirmed live
  against ClickHouse 24.8 (see module-level comments for how).
  """
  @spec decode_packet(binary) :: {:ok, term, binary} | {:incomplete, binary} | {:error, term}
  def decode_packet(binary) when is_binary(binary) do
    case Varint.decode(binary) do
      {:incomplete, _} ->
        {:incomplete, binary}

      {:ok, @server_data, rest} ->
        with {:ok, block, rest} <- ChDriver.Protocol.NativeBlock.decode_data_packet(rest) do
          {:ok, {:data, block}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_profile_events, rest} ->
        with {:ok, block, rest} <- ChDriver.Protocol.NativeBlock.decode_data_packet(rest) do
          {:ok, {:profile_events, block}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_exception, rest} ->
        with {:ok, error, rest} <- decode_exception_body(rest) do
          {:ok, {:exception, error}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_progress, rest} ->
        with {:ok, progress, rest} <- decode_progress_body(rest) do
          {:ok, {:progress, progress}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_profile_info, rest} ->
        with {:ok, profile_info, rest} <- decode_profile_info_body(rest) do
          {:ok, {:profile_info, profile_info}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_pong, rest} ->
        {:ok, :pong, rest}

      {:ok, @server_end_of_stream, rest} ->
        {:ok, :end_of_stream, rest}

      {:ok, other, _rest} ->
        {:error, {:unhandled_packet_type, other}}
    end
  end

  # Exception (Server packet type 2). Confirmed live in the 8a2.5 design
  # exploration and again here: Int32LE code, varint-length-prefixed name
  # ("DB::Exception"/"DB::NetException"), varint-length-prefixed message,
  # varint-length-prefixed stack trace string, trailing UInt8 has_nested
  # flag. See Exception::write / DB::writeException in
  # Common/Exception.cpp.
  defp decode_exception_body(binary) do
    with {:code, <<code::signed-little-32, rest::binary>>} <- {:code, binary},
         {:ok, name, rest} <- Varint.decode_string(rest),
         {:ok, message, rest} <- Varint.decode_string(rest),
         {:ok, stack_trace, rest} <- Varint.decode_string(rest),
         {:nested, <<has_nested::8, rest::binary>>} <- {:nested, rest} do
      error = %Error{
        code: code,
        name: name,
        message: message,
        stack_trace: stack_trace,
        has_nested: has_nested != 0
      }

      {:ok, error, rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:code, _} -> {:incomplete, binary}
      {:nested, _} -> {:incomplete, binary}
    end
  end

  # Progress (Server packet type 3). All fields gated on DBMS_MIN_* revision
  # constants that @client_revision always satisfies -- see
  # IO/Progress.cpp's ProgressValues::read/write.
  defp decode_progress_body(binary) do
    with {:ok, read_rows, rest} <- Varint.decode(binary),
         {:ok, read_bytes, rest} <- Varint.decode(rest),
         {:ok, total_rows_to_read, rest} <- Varint.decode(rest),
         {:ok, total_bytes_to_read, rest} <- Varint.decode(rest),
         {:ok, written_rows, rest} <- Varint.decode(rest),
         {:ok, written_bytes, rest} <- Varint.decode(rest),
         {:ok, elapsed_ns, rest} <- Varint.decode(rest) do
      progress = %{
        read_rows: read_rows,
        read_bytes: read_bytes,
        total_rows_to_read: total_rows_to_read,
        total_bytes_to_read: total_bytes_to_read,
        written_rows: written_rows,
        written_bytes: written_bytes,
        elapsed_ns: elapsed_ns
      }

      {:ok, progress, rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
    end
  end

  # ProfileInfo (Server packet type 6). Fields confirmed against
  # QueryPipeline/ProfileInfo.cpp's read/write at tag v24.8.14.39-lts --
  # BUT the source's `write` gates its trailing
  # applied_aggregation/rows_before_aggregation pair on
  # `client_revision >= DBMS_MIN_REVISION_WITH_ROWS_BEFORE_AGGREGATION`
  # (54469), where "client_revision" is the revision *we* advertised in
  # ClientHello (54465) -- NOT the server's own revision (54469, confirmed
  # live via ServerHello). Since 54465 < 54469, the server does NOT send
  # that trailing pair to us. Confirmed live: including it in the decoder
  # (as the constant alone would naively suggest) desyncs the stream and
  # corrupts every packet after -- caught by cross-checking decoded field
  # values against a byte-level replay of the same response.
  defp decode_profile_info_body(binary) do
    with {:ok, rows, rest} <- Varint.decode(binary),
         {:ok, blocks, rest} <- Varint.decode(rest),
         {:ok, bytes, rest} <- Varint.decode(rest),
         {:applied_limit, <<applied_limit::8, rest::binary>>} <- {:applied_limit, rest},
         {:ok, rows_before_limit, rest} <- Varint.decode(rest),
         {:calculated, <<calculated_rows_before_limit::8, rest::binary>>} <- {:calculated, rest} do
      profile_info = %{
        rows: rows,
        blocks: blocks,
        bytes: bytes,
        applied_limit: applied_limit != 0,
        rows_before_limit: rows_before_limit,
        calculated_rows_before_limit: calculated_rows_before_limit != 0
      }

      {:ok, profile_info, rest}
    else
      {:incomplete, _} -> {:incomplete, binary}
      {:applied_limit, _} -> {:incomplete, binary}
      {:calculated, _} -> {:incomplete, binary}
    end
  end
end
