defmodule ChDriver do
  @moduledoc """
  Native ClickHouse TCP-protocol driver, exposed as a `DBConnection` pool.

  ## Usage

      {:ok, pool} = ChDriver.start_link(hostname: "localhost", port: 9000)
      {:ok, %ChDriver.Result{columns: columns, rows: rows}} =
        ChDriver.query(pool, "SELECT number FROM system.numbers LIMIT 5")

  `start_link/1`, `query/2,3,4`, `query!/2,3,4`, and `stream/2,3,4` are the
  whole public surface. Everything else in this library is internal wiring
  (used directly by `Ecto.Adapters.ClickHouse`, but not meant to be called
  from application code).

  `start_link/1` accepts all of `ChDriver.Connection.connect/1`'s options
  (`:hostname`, `:port`, `:database`, `:username`, `:password`,
  `:connect_timeout`, `:recv_timeout`, `:compression`, `:settings`) plus
  the usual `DBConnection.start_link/2` pool options (`:pool_size`,
  `:name`, etc.), and forwards the connection options to every pooled
  connection.

  `:compression` (`:none` by default, or `:lz4`) turns on wire compression
  for query result blocks. Set it once at pool start, or override it per
  call via `query/4`'s `opts`.

  `:settings` (`[]` by default) applies real ClickHouse server settings
  (e.g. `settings: [{"async_insert", "0"}]`) to every query run through
  the pool by default. Set it once at pool start, or override/extend it
  per call via `query/4`'s own `:settings` opt — a setting name given
  per-call overrides the same name set at pool start, and anything only
  set at pool start still applies. This replaces having to inline a
  `SETTINGS x = y` clause into raw SQL text.
  """

  alias ChDriver.Query

  @doc """
  Starts a pool of ClickHouse connections.

  Returns `{:ok, pid}` (the pool to pass as `conn` to `query/2,3,4` or
  `stream/2,3,4`) or `{:error, reason}`.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(opts \\ []) do
    DBConnection.start_link(ChDriver.DBConnection, opts)
  end

  @doc """
  Runs `statement` against `conn` and returns its result.

  `statement` is a raw SQL string. It can contain plain `?` positional
  placeholders, or ClickHouse's own `{name:Type}` named placeholders written
  directly.

  `params` is the list of Elixir values to bind, in the same order as the
  `?`s (or `{name:Type}`s) in `statement`:

      ChDriver.query(pool, "SELECT * FROM events WHERE user_id = ?", [42])

  `conn` is a pool started by `start_link/1`, or any `DBConnection`-compatible
  connection reference.

  `opts[:settings]` (a list of `{name, value}` pairs, e.g.
  `settings: [{"async_insert", "0"}]`) applies real ClickHouse server
  settings to just this query, merged on top of (and overriding, by name)
  whatever `start_link/1`'s own `:settings` set as the pool-wide default.

  Returns `{:ok, %ChDriver.Result{}}` or `{:error, reason}`.
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
  Streams the rows of `statement` one wire-protocol block at a time, instead
  of loading the whole result into memory the way `query/2,3,4` does.

  Returns a `%ChDriver.Stream{}`, an `Enumerable` whose elements are
  `%ChDriver.Result{}` structs (one per block), honoring
  `opts[:decode_mapper]` the same way `query/2,3,4` does.

  `conn` must already be a checked-out connection, so `stream/2,3,4` has to
  be called from inside `DBConnection.run/3` or `DBConnection.transaction/3`,
  not directly against a pool:

      {:ok, result} =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream("SELECT number FROM system.numbers LIMIT 200000")
          |> Enum.take(5)
        end)

  Each block is only read off the socket when the consumer asks for the next
  one, so `Enum.take/2` on a large query genuinely avoids buffering rows you
  never asked for.
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
