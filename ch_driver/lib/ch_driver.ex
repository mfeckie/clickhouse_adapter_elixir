defmodule ChDriver do
  @moduledoc """
  Public API for the ClickHouse native-protocol driver: a `DBConnection`
  pool wrapping `ChDriver.Connection`'s TCP handshake and query encoding.

  ## Usage

      {:ok, pool} = ChDriver.start_link(hostname: "localhost", port: 9000)
      {:ok, %ChDriver.Result{columns: columns, rows: rows}} =
        ChDriver.query(pool, "SELECT number FROM system.numbers LIMIT 5")

  This is the intended integration point for higher layers (e.g. a future
  `Ecto.Adapters.SQL.Connection` implementation) -- `start_link/1` and
  `query/2,3` are the whole public surface; everything else
  (`ChDriver.DBConnection`, `ChDriver.Connection`, `ChDriver.Protocol`) is
  wiring underneath it.

  All `ChDriver.Connection.connect/1` options (`:hostname`, `:port`,
  `:database`, `:username`, `:password`, `:connect_timeout`,
  `:recv_timeout`) are accepted by `start_link/1` and forwarded to each
  pooled connection; standard `DBConnection.start_link/2` pool options
  (`:pool_size`, `:name`, etc.) are also accepted.
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
  `ChDriver.Protocol.param_text/1`/`escape_rounds/1` and `ChDriver.Query`'s
  moduledoc.
  """
  @spec query(DBConnection.conn(), binary, list, keyword) ::
          {:ok, ChDriver.Result.t()} | {:error, Exception.t()}
  def query(conn, statement, params \\ [], opts \\ []) do
    case DBConnection.execute(conn, %Query{statement: statement}, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end
end
