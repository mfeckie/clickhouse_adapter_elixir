defmodule ChDriver.Protocol do
  @moduledoc """
  ClickHouse native-protocol packet types relevant to the initial
  connection handshake.

  The Hello exchange (ClientHello sent, ServerHello received) happens in
  plaintext -- unlike Query/Data packets, it is never wrapped in a
  `ChNative.Block` compressed envelope.

  This module owns packet-type dispatch (`decode_packet/1`), the
  ClientHello/ServerHello struct definitions, and revision-gating
  predicates. Per-message byte layouts -- the actual encoding/decoding of
  each packet body -- live in `ChDriver.Protocol.Messages`.
  """

  alias ChDriver.Protocol.Messages
  alias ChDriver.Protocol.Varint

  # Server packet-type discriminants (varint-encoded) used by
  # `decode_packet/1` below. Client and server each have their own enum --
  # see ClickHouse's Protocol.h (Protocol::Client::Enum /
  # Protocol::Server::Enum), protocol revision 54469. Client-side
  # discriminants live in `ChDriver.Protocol.Messages`, next to the
  # encoders that use them.
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

  # Revision this driver advertises to the server. Also duplicated in
  # `ChDriver.Protocol.Messages`, which needs it for Hello/ClientInfo
  # encoding; kept here too since `addendum_required?/0` gates on it.
  @client_revision 54_465

  # DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM (Core/ProtocolDefines.h). Since
  # our advertised @client_revision is always above this, the driver always
  # sends the post-Hello Addendum. See `ChDriver.Protocol.Messages.encode_addendum/0`
  # for the full explanation of what the Addendum is and why skipping it
  # desyncs the connection.
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
    Messages.client_hello(default_database, user, password)
  end

  @doc """
  Encodes a `ClientHello` struct into the plaintext bytes sent to open a
  connection: packet-type varint (0), then client name/version/revision
  and the default_database/user/password length-prefixed strings.
  """
  @spec encode_client_hello(ClientHello.t()) :: iodata
  def encode_client_hello(%ClientHello{} = hello) do
    Messages.encode_client_hello(hello)
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
    Messages.decode_server_hello(binary)
  end

  @doc """
  Whether this driver's advertised revision requires sending the
  post-ServerHello Addendum (see `ChDriver.Protocol.Messages.encode_addendum/0`).
  Always `true` for `@client_revision`, but exposed so callers gate on the
  same constant the module uses internally.
  """
  @spec addendum_required? :: boolean
  def addendum_required?, do: @client_revision >= @min_revision_with_addendum

  @doc """
  Encodes the Addendum sent immediately after receiving ServerHello, when
  `addendum_required?/0` is true. See
  `ChDriver.Protocol.Messages.encode_addendum/0` for the wire layout and
  why this step is required.
  """
  @spec encode_addendum() :: iodata
  def encode_addendum, do: Messages.encode_addendum()

  @doc """
  Encodes a Query packet (Client packet type 1) for `query_string`.

  `opts` accepts:

    * `:query_id` -- defaults to `""`.
    * `:params` -- a list of `{name :: binary, raw_text :: binary}` pairs
      binding `query_string`'s `{name:Type}` placeholders (see
      `ChDriver.Params.text/1` for turning an Elixir value into
      `raw_text` and `ChDriver.Params.escape_rounds/1` for the matching
      escape depth -- a bare 2-tuple defaults to the scalar depth of 2).
      Defaults to `[]`.

  See `ChDriver.Protocol.Messages.encode_query/2` for the full wire layout.
  """
  @spec encode_query(binary, keyword) :: iodata
  def encode_query(query_string, opts \\ []) do
    Messages.encode_query(query_string, opts)
  end

  @doc """
  Encodes an empty Data packet (Client packet type 2): an empty external
  table, sent right after a Query packet to signal "no external tables /
  no input data" (required even for plain SELECTs). See
  `ChDriver.Protocol.Messages.encode_empty_data_packet/0` for the wire
  layout.
  """
  @spec encode_empty_data_packet() :: iodata
  def encode_empty_data_packet do
    Messages.encode_empty_data_packet()
  end

  @doc """
  Encodes a Ping packet (Client packet type 4). No body -- just the
  packet-type varint. The server replies with a bare Pong (Server packet
  type 4, see `@server_pong` / `decode_packet/1`) and nothing else.
  """
  @spec encode_ping() :: iodata
  def encode_ping, do: Messages.encode_ping()

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

  Packet type discriminants are documented in the module-level comments
  above; per-type field layouts live in `ChDriver.Protocol.Messages`.
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
        with {:ok, error, rest} <- Messages.decode_exception(rest) do
          {:ok, {:exception, error}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_progress, rest} ->
        with {:ok, progress, rest} <- Messages.decode_progress(rest) do
          {:ok, {:progress, progress}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_profile_info, rest} ->
        with {:ok, profile_info, rest} <- Messages.decode_profile_info(rest) do
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
end
