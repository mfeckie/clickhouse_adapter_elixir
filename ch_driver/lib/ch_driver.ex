defmodule ChDriver do
  @moduledoc """
  Public API for the ClickHouse native-protocol driver: a `DBConnection`
  pool wrapping `ChDriver.Connection`'s TCP handshake and query encoding.

  ## Usage

      {:ok, pool} = ChDriver.start_link(hostname: "localhost", port: 9000)
      {:ok, %ChDriver.Result{columns: columns, rows: rows}} =
        ChDriver.query(pool, "SELECT number FROM system.numbers LIMIT 5")

  This is the intended integration point for higher layers (e.g.
  `Ecto.Adapters.ClickHouse`) -- `start_link/1`, `query/2,3,4`,
  `query!/2,3,4`, and `stream/2,3,4` are the whole public surface;
  everything else (`ChDriver.DBConnection`, `ChDriver.Connection`,
  `ChDriver.Protocol`) is wiring underneath it.

  All `ChDriver.Connection.connect/1` options (`:hostname`, `:port`,
  `:database`, `:username`, `:password`, `:connect_timeout`,
  `:recv_timeout`, `:compression`) are accepted by `start_link/1` and
  forwarded to each pooled connection; standard `DBConnection.start_link/2`
  pool options (`:pool_size`, `:name`, etc.) are also accepted.

  `:compression` (`:none` (default) or `:lz4`) is opt-in wire compression
  for Data blocks -- off by default, so existing callers see unchanged
  behavior. It can also be overridden per call via `query/4`'s `opts`. See
  `ChDriver.Connection.connect/1` and
  `ChDriver.Protocol.Messages.encode_query/2` for how it's negotiated with
  the server.
  """

  alias ChDriver.Query

  @doc """
  Starts a `DBConnection` pool of ClickHouse native-protocol connections.

  Returns `{:ok, pid}` (the pool/pid to pass as `conn` to `query/2,3`) or
  `{:error, reason}`.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(opts \\ []) do
    DBConnection.start_link(ChDriver.DBConnection, opts)
  end

  @doc """
  Runs `statement` (a raw SQL string, optionally containing ClickHouse
  `{name:Type}` parameter placeholders) against `conn` (a pool started by
  `start_link/1`, or any `DBConnection`-compatible connection reference)
  and returns `{:ok, %ChDriver.Result{}}` or `{:error, reason}`.

  `params` is a list of `{name, raw_text}` or `{name, raw_text, escape_rounds}`
  tuples binding `statement`'s placeholders -- see
  `ChDriver.Params.text/1`/`ChDriver.Params.escape_rounds/1` and
  `ChDriver.Query`'s moduledoc.
  """
  @spec query(DBConnection.conn(), binary, list, keyword) ::
          {:ok, ChDriver.Result.t()} | {:error, Exception.t()}
  def query(conn, statement, params \\ [], opts \\ []) do
    # Always a freshly-built, never-parsed `%Query{}` (there is no cache
    # here to reuse an already-parsed struct across calls), so this must
    # go through `DBConnection.prepare_execute/4` (parse -> encode ->
    # execute), not `DBConnection.execute/4` (encode -> execute only,
    # which requires an already-parsed query -- see `ChDriver.Query`'s
    # moduledoc).
    case DBConnection.prepare_execute(conn, %Query{statement: statement}, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  @doc """
  Same as `query/4`, but returns the `%ChDriver.Result{}` directly on success
  and raises the underlying error instead of returning `{:error, reason}`.
  """
  @spec query!(DBConnection.conn(), binary, list, keyword) :: ChDriver.Result.t()
  def query!(conn, statement, params \\ [], opts \\ []) do
    case query(conn, statement, params, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Builds a `%ChDriver.Stream{}` that lazily executes `statement` and
  yields its rows one wire-protocol Data block at a time (each element is
  a `%ChDriver.Result{}` for that block, honoring `opts[:decode_mapper]`
  exactly like `query/2,3,4`), instead of buffering the whole result in
  memory the way `query/2,3,4` does.

  `conn` must already be a checked-out `%DBConnection{}` -- exactly what
  `DBConnection.stream/4` itself requires (its `resource/5` helper only
  matches an already-checked-out struct) -- so `stream/2,3,4` has to be
  called from inside `DBConnection.run/3` or `DBConnection.transaction/3`,
  not directly against a pool pid:

      {:ok, result} =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream("SELECT number FROM system.numbers LIMIT 200000")
          |> Enum.take(5)
        end)

  See `ChDriver.Stream`'s moduledoc and `ChDriver.DBConnection`'s cursor
  section for how the underlying `handle_declare/4`/`handle_fetch/4`/
  `handle_deallocate/4` cycle keeps this genuinely incremental (each
  block is only read off the socket when the consumer asks for it) rather
  than pre-buffering everything and merely presenting it lazily.
  """
  @spec stream(DBConnection.conn(), binary, list, keyword) :: ChDriver.Stream.t()
  def stream(%DBConnection{} = conn, statement, params \\ [], opts \\ []) do
    # `DBConnection.declare/4` (which `DBConnection.reduce/3` calls for a
    # plain `%DBConnection.Stream{}`, see `ChDriver.Stream`'s moduledoc)
    # only takes the "parse this fresh query first" path when
    # `DBConnection.Query.encode/3` raises `DBConnection.EncodeError` --
    # `ChDriver.Query`'s `encode/3` raises a plain `ArgumentError` for an
    # unparsed query instead (matching `Postgrex.Query`'s own behavior,
    # see its moduledoc), so a never-parsed struct would blow up there
    # instead of being auto-prepared. `parse/2` is a pure, local,
    # quote-aware lex with no socket I/O (see `ChDriver.Query.
    # lex_placeholders/1`), so doing it here upfront -- exactly like
    # `query/2,3,4` effectively does via `DBConnection.prepare_execute/4`
    # -- costs nothing extra and sidesteps the mismatch entirely.
    query = DBConnection.Query.parse(%Query{statement: statement}, opts)
    %ChDriver.Stream{conn: conn, query: query, params: params, opts: opts}
  end
end
