defmodule Ecto.Adapters.ClickHouse.Connection do
  @moduledoc """
  Implements `Ecto.Adapters.SQL.Connection` on top of `ChDriver`.

  Query params (`?` placeholders in generated SQL) are sent to ClickHouse
  as native protocol parameters rather than inlined as SQL literals, so
  there's no client-side value escaping to get wrong. `nil` is the one
  exception -- ClickHouse's parameter protocol has no type-independent
  NULL, so it's inlined as the literal `NULL` token instead.

  Statement generation lives in `Ecto.Adapters.ClickHouse.QueryBuilder`
  (`all/2`, `insert/8`, etc) and `Ecto.Adapters.ClickHouse.Expression`
  (clause/expression rendering); DDL generation lives in
  `Ecto.Adapters.ClickHouse.DDL`. This module implements the
  `Ecto.Adapters.SQL.Connection` behaviour itself and mostly delegates to
  those.
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

  @doc """
  Streams query results incrementally, one ClickHouse wire-protocol block
  at a time, rather than buffering the whole result set first.

  This adapter has no session transaction support, and `Repo.stream/2`
  requires a connection checked out via `Repo.transaction/2`, so
  `Repo.stream/2` does not work end-to-end on this adapter yet. Use
  `ChDriver.stream/4` directly against the repo's connection pool instead:

      %{pid: pool} = Ecto.Adapter.lookup_meta(MyApp.Repo)

      DBConnection.run(pool, fn conn ->
        ChDriver.stream(conn, "SELECT id, path FROM page_views", [])
        |> Enum.each(&IO.inspect/1)
      end)
  """
  @impl true
  def stream(conn, statement, params, opts) do
    statement = if is_binary(statement), do: statement, else: IO.iodata_to_binary(statement)
    ChDriver.stream(conn, statement, params, opts)
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
  defdelegate insert(
                prefix,
                table,
                header,
                rows,
                on_conflict,
                returning,
                placeholders,
                opts \\ []
              ),
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
