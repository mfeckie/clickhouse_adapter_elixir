defmodule ChDriver.Protocol.Messages do
  @moduledoc """
  Byte-level encoding and decoding for each ClickHouse native-protocol
  message: Hello, Addendum, Query (with its ClientInfo sub-structure), the
  empty Data packet, Ping, Exception, Progress, and ProfileInfo.

  This is internal to the driver. `ChDriver.Protocol` owns packet-type
  dispatch and calls into this module for the actual bytes.
  """

  alias ChDriver.Protocol.{ClientHello, ServerHello}
  alias ChDriver.Protocol.Varint
  alias ChDriver.Error

  # Client packet-type discriminants (varint-encoded). See `ChDriver.Protocol`
  # for the full Client/Server enum overview -- ClickHouse's Protocol.h
  # (Protocol::Client::Enum / Protocol::Server::Enum), protocol revision
  # 54469.
  @packet_hello 0
  @client_query 1
  @client_data 2
  @client_cancel 3
  @client_ping 4

  # Revision this driver advertises to the server. ClickHouse gates several
  # optional ServerHello fields (timezone, display name, version patch) on
  # the negotiated revision -- see DBMS_MIN_REVISION_WITH_* constants in
  # Core/ProtocolDefines.h. 54465 is well above all of them, so a real
  # server always sends the full ServerHello shape below when we advertise
  # this revision.
  @client_revision 54_465
  @client_version_major 24
  @client_version_minor 8
  @client_version_patch 0
  @client_name "ChDriver"

  @min_revision_with_server_timezone 54_058
  @min_revision_with_server_display_name 54_372
  @min_revision_with_version_patch 54_401

  @doc """
  This driver's advertised protocol revision (`@client_revision`).
  """
  @spec client_revision() :: non_neg_integer
  def client_revision, do: @client_revision

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
  Encodes the Addendum sent immediately after receiving ServerHello, when
  `ChDriver.Protocol.addendum_required?/0` is true.

  Not a full packet — just a raw length-prefixed string (the quota key,
  always sent empty here), with no leading packet-type varint. This must
  be sent before any Query packet; see `ChDriver.Protocol.addendum_required?/0`.
  """
  @spec encode_addendum() :: iodata
  def encode_addendum, do: Varint.encode_string("")

  @query_stage_complete 2
  @compression_disabled 0
  @compression_enabled 1

  # The "custom setting" flag bit (Core/BaseSettingsFwdDeclsGen.h /
  # SettingsWriteFormat) marking a settings-changes entry as a named
  # value outside the fixed Settings schema rather than a real server
  # setting. Query parameters piggyback on exactly this mechanism: the
  # bytes after the query string are the *same* (name, flags, value)
  # triple format as the per-query settings block earlier in the packet,
  # just with this flag always set. For example, `SELECT {id:UInt64}`
  # bound to `--param_id=5` puts `02` (this flag) between the "id" name
  # string and the `'5'` value string.
  @custom_setting_flag 2

  # A real per-query SETTINGS entry uses the *same* (name, flags, value)
  # triple format as `@custom_setting_flag` query parameters, but with the
  # CUSTOM bit (0x02) clear. BaseSettings<TTraits>::write's
  # SettingsWriteFormat::STRINGS_WITH_FLAGS defines two flag bits on that
  # byte: IMPORTANT (0x01 -- "a server that doesn't recognize this setting
  # name should hard-fail instead of silently ignoring it") and CUSTOM
  # (0x02 -- "this is a user-namespaced/query-parameter setting, not a
  # real entry in the fixed Settings schema", see `@custom_setting_flag`).
  # A genuine built-in setting like `async_insert` or `max_block_size`
  # needs neither bit: flags 0. Verified empirically against a live
  # ClickHouse server (not from documentation alone) two ways: sending
  # `max_block_size` as a per-query setting with flags 0 measurably changes
  # the number of Data blocks a large SELECT is chunked into, and sending
  # `async_insert = 0` this way (instead of inlined in SQL text) makes a
  # subsequent SELECT observe an INSERT synchronously. See
  # `ch_driver/test/ch_driver/settings_test.exs`.
  @setting_flag 0

  @doc """
  Encodes a Query packet for `query_string`.

  `opts` accepts:

    * `:query_id` -- defaults to `""` (the server generates one).
    * `:params` -- a list of `{name, raw_text}` or `{name, raw_text, rounds}`
      tuples binding `query_string`'s `{name:Type}` placeholders. Build
      these from Elixir values with `ChDriver.Params.text/1` and
      `ChDriver.Params.escape_rounds/1`. Defaults to `[]`.
    * `:settings` -- a list of `{name, value}` pairs (both strings, or any
      term `to_string/1` accepts) applying real ClickHouse server settings
      to just this query, e.g. `settings: [{"async_insert", "0"}]` --
      equivalent to inlining `SETTINGS async_insert = 0` into the SQL text,
      but composable and independent of the query string. Defaults to
      `[]`.
    * `:compression` -- `:none` (default) or `:lz4`. Setting this to `:lz4`
      tells the server that both directions of this query's block traffic
      (Data, ProfileEvents) will be wrapped in a
      `ChDriver.Protocol.Block.Compressed` envelope from here on — every
      packet sent after this one, in either direction, needs to match.
  """
  @spec encode_query(binary, keyword) :: iodata
  def encode_query(query_string, opts \\ []) do
    query_id = Keyword.get(opts, :query_id, "")
    params = Keyword.get(opts, :params, [])
    settings = Keyword.get(opts, :settings, [])
    compression_flag = compression_flag(Keyword.get(opts, :compression, :none))

    [
      Varint.encode(@client_query),
      Varint.encode_string(query_id),
      encode_client_info(),
      encode_settings(settings),
      Varint.encode_string(""),
      Varint.encode(@query_stage_complete),
      Varint.encode(compression_flag),
      Varint.encode_string(query_string),
      encode_query_parameters(params)
    ]
  end

  # Same wire shape as `encode_query_parameters/1` below (name/flags/value
  # triples, terminated by an empty name), but with `@setting_flag` (0)
  # instead of `@custom_setting_flag` -- see the comment above
  # `@setting_flag` for why that distinction matters.
  defp encode_settings(settings) do
    [
      Enum.map(settings, fn {name, value} -> encode_one_setting(name, value) end),
      Varint.encode_string("")
    ]
  end

  defp encode_one_setting(name, value) do
    [
      Varint.encode_string(to_string(name)),
      Varint.encode(@setting_flag),
      Varint.encode_string(to_string(value))
    ]
  end

  defp compression_flag(:none), do: @compression_disabled
  defp compression_flag(:lz4), do: @compression_enabled

  # Each parameter is a (name, flags, value) triple identical in shape to
  # a per-query settings entry, terminated by an empty name -- see
  # `@custom_setting_flag`. `value` is always sent as a single-quoted,
  # backslash-escaped string, regardless of the parameter's declared
  # `{name:Type}` -- the server re-parses this text as a literal against
  # that type. For example, `--param_id=5` bound to `{id:UInt64}` sends
  # the three bytes `'`, `5`, `'` as the value, not a raw UInt64.
  defp encode_query_parameters(params) do
    [
      Enum.map(params, fn
        {name, raw_text, rounds} -> encode_one_param(name, raw_text, rounds)
        {name, raw_text} -> encode_one_param(name, raw_text, 2)
      end),
      Varint.encode_string("")
    ]
  end

  defp encode_one_param(name, raw_text, rounds) do
    [
      Varint.encode_string(name),
      Varint.encode(@custom_setting_flag),
      Varint.encode_string(ChDriver.Params.quote_param_value(raw_text, rounds))
    ]
  end

  # ClientInfo sub-structure written as part of a Query packet. Field order
  # matches ClickHouse's Interpreters/ClientInfo.cpp (write/read). Every
  # optional field below is gated (in the real source) on a
  # DBMS_MIN_REVISION_WITH_* constant that `@client_revision` (54465)
  # always satisfies, so we always emit them -- see the revision table in
  # the moduledoc-adjacent comments above.
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
  Encodes the empty Data packet ClickHouse requires right after every
  Query packet, signaling "no external tables, no input data" — required
  even for a plain `SELECT`.

  `compression` (`:none` (default) or `:lz4`) must match whatever was
  negotiated for this query via `encode_query/2`'s `:compression` opt.
  """
  @spec encode_empty_data_packet(ChDriver.Protocol.Block.Compressed.method()) :: iodata
  def encode_empty_data_packet(compression \\ :none) do
    block_body = [
      empty_block_info(),
      Varint.encode(0),
      Varint.encode(0)
    ]

    [
      Varint.encode(@client_data),
      Varint.encode_string(""),
      encode_block_body(block_body, compression)
    ]
  end

  defp encode_block_body(block_body, :none), do: block_body

  defp encode_block_body(block_body, :lz4),
    do: ChDriver.Protocol.Block.Compressed.encode(block_body, :lz4)

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
  Encodes a Ping packet. The server replies with a bare Pong and nothing
  else.
  """
  @spec encode_ping() :: iodata
  def encode_ping, do: Varint.encode(@client_ping)

  @doc """
  Encodes a Cancel packet, telling the server to stop running the query
  currently in progress on this connection. The caller must keep reading
  until `:end_of_stream` afterward — see `ChDriver.Connection.cancel_stream/2`.
  """
  @spec encode_cancel() :: iodata
  def encode_cancel, do: Varint.encode(@client_cancel)

  # Exception (Server packet type 2): Int32LE code, varint-length-prefixed
  # name ("DB::Exception"/"DB::NetException"), varint-length-prefixed
  # message, varint-length-prefixed stack trace string, trailing UInt8
  # has_nested flag. See Exception::write / DB::writeException in
  # Common/Exception.cpp.
  @doc false
  def decode_exception(binary) do
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
  @doc false
  def decode_progress(binary) do
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

  # ProfileInfo (Server packet type 6). Fields match
  # QueryPipeline/ProfileInfo.cpp's read/write, EXCEPT the source's `write`
  # gates its trailing applied_aggregation/rows_before_aggregation pair on
  # `client_revision >= DBMS_MIN_REVISION_WITH_ROWS_BEFORE_AGGREGATION`
  # (54469), where "client_revision" is the revision *we* advertised in
  # ClientHello (54465) -- NOT the server's own revision (54469). Since
  # 54465 < 54469, the server does NOT send that trailing pair to us;
  # including it in the decoder (as the constant alone would naively
  # suggest) desyncs the stream and corrupts every packet after.
  @doc false
  def decode_profile_info(binary) do
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
