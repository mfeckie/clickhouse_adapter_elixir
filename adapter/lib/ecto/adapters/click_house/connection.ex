defmodule Ecto.Adapters.ClickHouse.Connection do
  @moduledoc """
  Implements `Ecto.Adapters.SQL.Connection` on top of `ChDriver`.

  ## Parameter binding

  SQL is generated the normal Ecto way with `?` placeholders (see
  `expr/3`, `insert/8`), matching every other `Ecto.Adapters.SQL.Connection`
  implementation. Rather than inlining the corresponding runtime values as
  SQL literals, `%ChDriver.Query{}`'s `DBConnection.Query` implementation
  (see `ch_driver/lib/ch_driver/query.ex`) rewrites each `?` into a
  ClickHouse native `{pN:Type}` parameter placeholder and sends the actual
  value alongside the query through `ChDriver`'s query-parameters wire
  mechanism (see `ChDriver.Protocol.encode_query/2`) -- the value's bytes
  never pass through the SQL text at all, so there's nothing to escape and
  no `?` inside a string literal or raw fragment can be mistaken for a
  bind placeholder (the one-time lexer this drives, `ChDriver.Query.
  lex_placeholders/1`, tracks quoted regions while scanning).

  ClickHouse's parameter mechanism has no type-independent way to express
  NULL (see `ChDriver.Params.text/1`), so a `nil` value is the one
  exception: it's inlined directly as the literal `NULL` token, which
  carries no injection risk since it's a fixed constant.

  This module itself no longer does any of that lexing/binding -- it just
  builds a `%ChDriver.Query{statement: sql}` and lets `DBConnection`'s
  normal parse/encode/execute flow (driven by `Ecto.Adapters.SQL`'s own
  query cache) do it, once per distinct prepared query shape rather than
  on every execute. See `ChDriver.Query`'s moduledoc for the full
  rationale.
  """

  @behaviour Ecto.Adapters.SQL.Connection

  alias Ecto.Adapters.ClickHouse.QueryBuilder

  ## Connection

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(ChDriver.DBConnection, opts)
  end

  ## Query execution

  @impl true
  def prepare_execute(conn, _name, sql, params, opts) do
    statement = IO.iodata_to_binary(sql)

    # A fresh, never-parsed query struct -- `DBConnection.prepare_execute/4`
    # runs it through `DBConnection.Query.parse/2` (the one-time `?` lexer),
    # then `encode/3`, then `handle_execute/4`. The returned, now-parsed
    # struct is what `Ecto.Adapters.SQL`'s query cache holds onto and later
    # passes back into `execute/4` below -- that's what skips re-parsing on
    # every subsequent execution of the same prepared query.
    case DBConnection.prepare_execute(conn, %ChDriver.Query{statement: statement}, params, opts) do
      {:ok, query, result} -> {:ok, query, to_sql_result(result)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def execute(conn, %ChDriver.Query{} = query, params, opts) do
    # `query` here is the already-parsed struct `prepare_execute/5` (or a
    # previous `execute/4`) returned -- `DBConnection.execute/4` only runs
    # `encode/3` (using its cached `param_names`) and `handle_execute/4`,
    # not `parse/2` again.
    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, to_sql_result(result)}
      {:error, _} = error -> error
    end
  end

  def execute(conn, statement, params, opts) when is_binary(statement) do
    execute(conn, %ChDriver.Query{statement: statement}, params, opts)
  end

  @impl true
  def query(conn, statement, params, opts) do
    statement = IO.iodata_to_binary(statement)

    # No cache to reuse a parsed struct from (mirrors `:nocache` semantics),
    # so this always goes through the full parse/encode/execute path, same
    # as `prepare_execute/5` above.
    case DBConnection.prepare_execute(conn, %ChDriver.Query{statement: statement}, params, opts) do
      {:ok, _query, result} -> {:ok, to_sql_result(result)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def query_many(_conn, _statement, _params, _opts) do
    {:error,
     RuntimeError.exception(
       "query_many/4 is not supported: ClickHouse's native protocol as used by ChDriver " <>
         "only executes a single statement per query round-trip"
     )}
  end

  @impl true
  def stream(_conn, _statement, _params, _opts) do
    raise RuntimeError,
          "Repo.stream/2 is not supported by the ClickHouse adapter: ChDriver.DBConnection " <>
            "has no cursor support (handle_declare/handle_fetch are unimplemented stubs) " <>
            "because the ClickHouse native protocol used here has no server-side cursor " <>
            "concept -- use Repo.all/2 instead"
  end

  @impl true
  def to_constraints(_exception, _opts), do: []

  defp to_sql_result(%ChDriver.Result{columns: columns, rows: rows, num_rows: num_rows}) do
    %{columns: Enum.map(columns, fn {name, _type} -> name end), rows: rows, num_rows: num_rows}
  end

  ## Query generation
  ##
  ## Statement generation (all/update_all/delete_all/insert/update/delete/
  ## explain_query) lives in `Ecto.Adapters.ClickHouse.QueryBuilder`, and the
  ## clause/expression rendering it depends on lives in
  ## `Ecto.Adapters.ClickHouse.Expression` -- see their moduledocs. The
  ## functions below are thin delegations kept here only because they're
  ## `@impl true` callbacks of the `Ecto.Adapters.SQL.Connection` behaviour,
  ## which Ecto expects this module (not `QueryBuilder`) to implement.
  @impl true
  defdelegate all(query, as_prefix \\ []), to: QueryBuilder

  @impl true
  defdelegate update_all(query, prefix \\ nil), to: QueryBuilder

  @impl true
  defdelegate delete_all(query), to: QueryBuilder

  @impl true
  defdelegate insert(prefix, table, header, rows, on_conflict, returning, placeholders, opts \\ []),
    to: QueryBuilder

  @impl true
  defdelegate update(prefix, table, fields, filters, returning), to: QueryBuilder

  @impl true
  defdelegate delete(prefix, table, filters, returning), to: QueryBuilder

  @impl true
  defdelegate explain_query(conn, query_string, params, opts), to: QueryBuilder

  ## DDL
  ##
  ## DDL generation (CREATE/DROP TABLE, column type mapping, and the design
  ## rationale for what is and isn't supported) lives in
  ## `Ecto.Adapters.ClickHouse.DDL` -- see its moduledoc. The functions below
  ## are thin delegations kept here only because `execute_ddl/1`, `ddl_logs/1`,
  ## and `table_exists_query/1` are `@impl true` callbacks of the
  ## `Ecto.Adapters.SQL.Connection` behaviour, which Ecto expects this module
  ## (not `DDL`) to implement.
  @impl true
  defdelegate execute_ddl(command), to: Ecto.Adapters.ClickHouse.DDL

  @impl true
  defdelegate ddl_logs(result), to: Ecto.Adapters.ClickHouse.DDL

  @impl true
  defdelegate table_exists_query(table), to: Ecto.Adapters.ClickHouse.DDL

end

