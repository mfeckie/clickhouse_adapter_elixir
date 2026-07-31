defmodule ChDriver.Protocol do
  @moduledoc """
  Encodes and decodes ClickHouse native-protocol packets.

  This is internal to the driver — application code talks to ClickHouse
  through `ChDriver`, not this module directly.

  Covers the connection handshake (`client_hello/3`, `encode_client_hello/1`,
  `decode_server_hello/1`), building outgoing Query/Ping/Cancel packets, and
  dispatching incoming server packets to the right decoder
  (`decode_packet/2`). Per-message byte layouts live in
  `ChDriver.Protocol.Messages`; this module owns packet-type dispatch and
  the ClientHello/ServerHello struct definitions.
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

  # DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM (Core/ProtocolDefines.h). Since
  # our advertised revision (`ChDriver.Protocol.Messages.client_revision/0`)
  # is always above this, the driver always sends the post-Hello Addendum.
  # See `ChDriver.Protocol.Messages.encode_addendum/0` for the full
  # explanation of what the Addendum is and why skipping it desyncs the
  # connection.
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

    @type t :: %__MODULE__{
            client_name: String.t(),
            version_major: non_neg_integer,
            version_minor: non_neg_integer,
            version_patch: non_neg_integer,
            revision: non_neg_integer,
            default_database: String.t(),
            user: String.t(),
            password: String.t()
          }
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

    @type t :: %__MODULE__{
            name: String.t() | nil,
            version_major: non_neg_integer | nil,
            version_minor: non_neg_integer | nil,
            revision: non_neg_integer | nil,
            timezone: String.t() | nil,
            display_name: String.t() | nil,
            version_patch: non_neg_integer | nil
          }
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
  Whether the handshake needs to send an Addendum packet after ServerHello.
  Always `true` for this driver's advertised protocol revision.
  """
  @spec addendum_required? :: boolean
  def addendum_required?, do: Messages.client_revision() >= @min_revision_with_addendum

  @doc """
  Encodes the Addendum packet sent right after receiving ServerHello, when
  `addendum_required?/0` is true.
  """
  @spec encode_addendum() :: iodata
  def encode_addendum, do: Messages.encode_addendum()

  @doc """
  Encodes a Query packet for `query_string`.

  `opts` accepts:

    * `:query_id` -- defaults to `""`.
    * `:params` -- a list of `{name, raw_text}` or `{name, raw_text, rounds}`
      tuples binding `query_string`'s `{name:Type}` placeholders. Build
      these from Elixir values with `ChDriver.Params.text/1` and
      `ChDriver.Params.escape_rounds/1`. Defaults to `[]`.
    * `:compression` -- `:none` (default) or `:lz4`.
  """
  @spec encode_query(binary, keyword) :: iodata
  def encode_query(query_string, opts \\ []) do
    Messages.encode_query(query_string, opts)
  end

  @doc """
  Encodes the empty Data packet ClickHouse requires right after every
  Query packet, even for a plain `SELECT`. `compression` must match
  whatever was passed as `encode_query/2`'s `:compression` for this query.
  """
  @spec encode_empty_data_packet(ChDriver.Protocol.Block.Compressed.method()) :: iodata
  def encode_empty_data_packet(compression \\ :none) do
    Messages.encode_empty_data_packet(compression)
  end

  @doc """
  Encodes a Ping packet. The server replies with a bare Pong and nothing
  else.
  """
  @spec encode_ping() :: iodata
  def encode_ping, do: Messages.encode_ping()

  @doc """
  Encodes a Cancel packet, telling the server to stop running the query
  currently in progress on this connection. The caller must keep reading
  until `:end_of_stream` afterward — see `ChDriver.Connection.cancel_stream/2`.
  """
  @spec encode_cancel() :: iodata
  def encode_cancel, do: Messages.encode_cancel()

  @doc """
  Decodes a single server response packet from the front of `binary`.

  Returns `{:ok, packet, rest}`, `{:incomplete, binary}` if more bytes are
  needed (buffer more and retry), or `{:error, reason}`.

  `packet` is one of:

    * `{:data, %{table_name:, columns:, rows:}}` -- a query result block.
    * `{:profile_events, %{table_name:, columns:, rows:}}` -- internal
      query execution metrics, wire-identical to `:data`.
    * `{:progress, %{read_rows:, read_bytes:, total_rows_to_read:,
      total_bytes_to_read:, written_rows:, written_bytes:, elapsed_ns:}}`
    * `:pong`
    * `:end_of_stream`
    * `{:exception, %ChDriver.Error{}}`

  `compression` (`:none` (default) or `:lz4`) must match whatever was
  negotiated for this query via `encode_query/2`'s `:compression` opt.
  It only affects how Data packets' block bodies are decoded; ProfileEvents
  and every other packet type are always plain regardless of compression.
  """
  @spec decode_packet(binary, ChDriver.Protocol.Block.Compressed.method()) ::
          {:ok, term, binary} | {:incomplete, binary} | {:error, term}
  def decode_packet(binary, compression \\ :none) when is_binary(binary) do
    case Varint.decode(binary) do
      {:incomplete, _} ->
        {:incomplete, binary}

      {:ok, @server_data, rest} ->
        with {:ok, block, rest} <-
               ChDriver.Protocol.NativeBlock.decode_data_packet(rest, compression) do
          {:ok, {:data, block}, rest}
        else
          {:incomplete, _} -> {:incomplete, binary}
          {:error, reason} -> {:error, reason}
        end

      {:ok, @server_profile_events, rest} ->
        with {:ok, block, rest} <-
               ChDriver.Protocol.NativeBlock.decode_data_packet(rest, :none) do
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
