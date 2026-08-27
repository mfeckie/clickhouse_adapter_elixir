defmodule Ecto.Adapters.ClickHouse.QueryBuilder do
  @moduledoc """
  Statement generators for `Ecto.Adapters.SQL.Connection`: `all/2`,
  `update_all/2`, `delete_all/1`, `insert/8`, `update/5`, `delete/5`, and
  `explain_query/4`.

  `update_all/2`, `update/5`, and `delete/5` always raise: ClickHouse
  mutates existing rows asynchronously via `ALTER TABLE ...
  UPDATE`/`DELETE`, not a synchronous SQL statement, so
  `Repo.update_all/2`, `Repo.update!/1`, and `Repo.delete!/1` aren't
  supported. Issue an `ALTER TABLE` mutation directly via a raw query
  instead.

  `delete_all/1` is supported, but narrowly: it compiles to
  `ALTER TABLE ... DELETE WHERE ... SETTINGS mutations_sync = 1`, which
  only accepts a single source table and no joins/`LIMIT`/`OFFSET` --
  queries outside that shape raise. `mutations_sync = 1` makes the call
  block until the mutation is actually applied, which is what lets
  `Repo.delete_all/2` behave synchronously (useful in a migration's
  `down/0`) at the cost of not scaling to large bulk deletes -- prefer a
  raw, unsynchronized `ALTER TABLE ... DELETE` for those.

  `insert/8` doesn't support `:on_conflict` (no native upsert -- use
  `ReplacingMergeTree`/`CollapsingMergeTree` engines instead) or
  `:returning` (no `RETURNING` clause).

  `all/2` renders non-recursive `with_cte/3` common table expressions (both
  the `^existing_query` and `fragment(...)` forms) onto ClickHouse's own
  `WITH name AS (subquery) SELECT ...` clause -- see `cte/2` below for what's
  explicitly out of scope (recursive CTEs, `:materialized`, non-`:all`
  operations) and why.
  """

  alias Ecto.Adapters.ClickHouse.{Connection, Expression, Naming}
  alias Ecto.Query.{QueryExpr, WithExpr}

  @doc false
  def all(query, as_prefix \\ []) do
    sources = Naming.create_names(query, as_prefix)

    cte = cte(query, sources)
    from = Expression.from(query, sources)
    select = Expression.select(query, sources)
    join = Expression.join(query, sources)
    where = Expression.where(query, sources)
    group_by = Expression.group_by(query, sources)
    having = Expression.having(query, sources)
    order_by = Expression.order_by(query, sources)
    limit = Expression.limit(query, sources)
    offset = Expression.offset(query, sources)

    unless query.windows == [] and query.combinations == [] do
      Naming.error!(query, "the ClickHouse adapter does not support windows/set operations yet")
    end

    [cte, select, from, join, where, group_by, having, order_by, limit, offset]
  end

  ## `WITH` (common table expressions) -- `with_cte/3`'s non-recursive form
  ## renders straightforwardly onto ClickHouse's own `WITH name AS (subquery)
  ## SELECT ...` clause, which every currently-supported (`26.7`) ClickHouse
  ## version accepts ahead of a `SELECT`.
  ##
  ## Explicitly out of scope (raise instead of silently mishandling):
  ##
  ##   * `recursive_ctes(query, true)`/`with_cte(..., recursive: true)` --
  ##     ClickHouse has no `WITH RECURSIVE`; there is no SQL this adapter
  ##     could emit for it.
  ##   * `with_cte(..., materialized: true | false)` -- Postgres-specific
  ##     `MATERIALIZED`/`NOT MATERIALIZED` CTE inlining hint, which
  ##     ClickHouse's `WITH` clause has no equivalent modifier for.
  ##   * `with_cte(..., operation: :update_all | :delete_all)` -- ClickHouse's
  ##     `WITH` clause only ever takes a `SELECT` subquery (or a scalar
  ##     expression), and this adapter doesn't implement `update_all`/
  ##     `delete_all` as real SQL statements regardless (see below).
  @doc false
  def cte(%{with_ctes: nil}, _sources), do: []
  def cte(%{with_ctes: %WithExpr{queries: []}}, _sources), do: []

  def cte(%{with_ctes: %WithExpr{recursive: true}} = query, _sources) do
    Naming.error!(
      query,
      "the ClickHouse adapter does not support recursive CTEs -- ClickHouse has no " <>
        "`WITH RECURSIVE` equivalent"
    )
  end

  def cte(%{with_ctes: %WithExpr{queries: queries}} = query, sources) do
    ["WITH ", Enum.map_intersperse(queries, ", ", &cte_expr(&1, sources, query)), " "]
  end

  defp cte_expr({_name, %{materialized: materialized}, _cte}, _sources, query)
       when is_boolean(materialized) do
    Naming.error!(
      query,
      "the ClickHouse adapter does not support the `:materialized` CTE option -- ClickHouse's " <>
        "`WITH` clause has no `MATERIALIZED`/`NOT MATERIALIZED` modifier"
    )
  end

  defp cte_expr({name, opts, cte}, sources, query) do
    case Map.get(opts, :operation, :all) do
      operation when operation in [nil, :all] ->
        [Naming.quote_name(name), " AS (", cte_query(cte, sources, query), ?)]

      operation ->
        Naming.error!(
          query,
          "the ClickHouse adapter only supports :all-operation CTEs (got #{inspect(operation)}) " <>
            "-- ClickHouse's `WITH` clause only takes a SELECT subquery, and update_all/delete_all " <>
            "aren't implemented as real SQL statements by this adapter regardless"
        )
    end
  end

  defp cte_query(%Ecto.Query{} = cte_query, _sources, _query), do: all(cte_query, [])

  defp cte_query(%QueryExpr{expr: expr}, sources, query),
    do: Expression.expr(expr, sources, query)

  @doc false
  def update_all(query, _prefix \\ nil) do
    Naming.error!(
      query,
      "the ClickHouse adapter does not support UPDATE: ClickHouse mutates existing data via " <>
        "the asynchronous `ALTER TABLE ... UPDATE` statement, not a synchronous SQL UPDATE, " <>
        "so update_all/2 is unimplemented -- issue an ALTER TABLE mutation " <>
        "directly via a raw query if you need this"
    )
  end

  ## `delete_all/1` -- narrowly scoped support
  ##
  ## ClickHouse has no synchronous `DELETE`; row removal goes through the
  ## `ALTER TABLE ... DELETE WHERE ...` mutation, which is queued and applied
  ## in the background by default. However, that mutation accepts a
  ## `SETTINGS mutations_sync = 1` clause that makes the *issuing client*
  ## block until the mutation has actually been applied locally before the
  ## query returns. That's exactly
  ## what's needed to make `Ecto.Migration.SchemaMigration`'s `down/4`'s
  ## `repo.delete_all(from m in "schema_migrations", where: m.version == ^v)`
  ## behave synchronously enough for `Ecto.Migrator.run(repo, path, :down,
  ## ...)` to work: insert the row (`up`), delete it and immediately have it
  ## gone (`down`), no polling or manual mutation-tracking required.
  ##
  ## This is a mutation under the hood, not a real transactional
  ## DELETE, so the scope here is narrow, limited to what maps cleanly
  ## onto a single `ALTER TABLE ... DELETE WHERE <cond>`:
  ##
  ##   * a single source table (no joins)
  ##   * no LIMIT/OFFSET (mutations have no concept of either)
  ##
  ## `mutations_sync = 1` only waits for the mutation to finish on the node
  ## that received the query -- on a replicated/multi-node cluster you'd want
  ## `mutations_sync = 2` to wait for all replicas; this adapter only targets
  ## single-node ClickHouse, so `1` is sufficient and cheaper. General
  ## multi-row bulk-delete workloads on large MergeTree tables should still
  ## prefer an unsynchronized `ALTER TABLE ... DELETE` (fire-and-forget) via
  ## a raw query instead of this -- forcing every mutation to block until
  ## fully applied is fine for a handful of `schema_migrations` bookkeeping
  ## rows, but would be a real throughput/latency problem at scale.
  @doc false
  def delete_all(%{sources: sources} = query) do
    unless query.joins == [] do
      Naming.error!(
        query,
        "the ClickHouse adapter does not support joins in delete_all/2 -- ClickHouse's " <>
          "`ALTER TABLE ... DELETE` mutation (see the moduledoc above) only accepts a bare " <>
          "WHERE clause against a single table, with no join support; this is a deliberate " <>
          "scope limit, not a temporary gap -- issue the equivalent as a raw " <>
          "`ALTER TABLE ... DELETE WHERE <subquery-based condition>` query instead if you " <>
          "need join-driven delete semantics"
      )
    end

    unless query.limit == nil and query.offset == nil do
      Naming.error!(
        query,
        "the ClickHouse adapter does not support LIMIT/OFFSET in delete_all/2 -- " <>
          "ClickHouse's `ALTER TABLE ... DELETE` mutation only accepts a WHERE clause"
      )
    end

    unless tuple_size(sources) == 1 do
      Naming.error!(
        query,
        "the ClickHouse adapter only supports delete_all/1 against a single source"
      )
    end

    # Unlike `all/2`, `ALTER TABLE ... DELETE` has no `FROM ... AS alias`
    # clause to declare a table alias against -- it's always exactly one
    # bare table name. Build a one-element sources tuple with an empty
    # alias so `Expression.where/2`/`Expression.expr/3` emit unqualified
    # `"version"` instead of `s0."version"` (which ClickHouse would reject:
    # "Missing columns: 's0.version'" -- there's no `s0` in scope here).
    {table, schema, prefix} = elem(sources, 0)
    table_sql = Naming.quote_table(prefix, table)
    delete_sources = {{table_sql, "", schema}}

    # `ALTER TABLE ... DELETE` requires a WHERE clause (unlike a plain SQL
    # DELETE, ClickHouse has no unconditional-delete-everything form of the
    # mutation) -- `Expression.where/2` returns `[]` when the query has no
    # `where(...)` at all, so fall back to an always-true condition to
    # delete every row, matching `Repo.delete_all(query)` semantics with no
    # filter.
    where_clause =
      case query.wheres do
        [] -> " WHERE 1"
        _ -> Expression.where(query, delete_sources)
      end

    [
      "ALTER TABLE ",
      table_sql,
      " DELETE",
      where_clause,
      " SETTINGS mutations_sync = 1"
    ]
  end

  @doc false
  def insert(prefix, table, header, rows, on_conflict, returning, placeholders, opts \\ [])

  def insert(_prefix, _table, _header, _rows, _on_conflict, [_ | _], _placeholders, _opts) do
    raise ArgumentError,
          "the ClickHouse adapter does not support :returning -- ClickHouse's INSERT has no " <>
            "RETURNING clause"
  end

  def insert(prefix, table, header, rows, {:raise, _, []}, [], placeholders, _opts) do
    fields = Naming.quote_names(header)

    [
      "INSERT INTO ",
      Naming.quote_table(prefix, table),
      " (",
      fields,
      ") VALUES " | insert_all(rows, placeholders)
    ]
  end

  def insert(_prefix, _table, _header, _rows, _on_conflict, [], _placeholders, _opts) do
    raise ArgumentError,
          "the ClickHouse adapter does not support :on_conflict -- ClickHouse has no native " <>
            "upsert; use ReplacingMergeTree/CollapsingMergeTree table engines and plain " <>
            "INSERTs instead"
  end

  defp insert_all(rows, _placeholders) when is_list(rows) do
    Enum.map_intersperse(rows, ?,, fn row ->
      [?(, Enum.map_intersperse(row, ?,, &insert_all_value/1), ?)]
    end)
  end

  defp insert_all_value(nil), do: "NULL"
  defp insert_all_value(_), do: "?"

  # update/5 and delete/4 are only reachable via a direct call to this
  # module (e.g. from a raw script) -- Ecto.Adapter.Schema's `update/6` and
  # `delete/5` in Ecto.Adapters.ClickHouse are overridden to raise directly
  # instead of going through these, so Ecto.Repo.update!/delete! never hits
  # them. See the comment there for why: it dodges a spurious "will never
  # match" type-checker warning caused by these always-raising functions
  # inferring a `none()` return type.
  @doc false
  def update(_prefix, _table, _fields, _filters, _returning) do
    raise ArgumentError,
          "the ClickHouse adapter does not support UPDATE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... UPDATE` statement, not a synchronous SQL " <>
            "UPDATE, so update/5 is unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @doc false
  def delete(_prefix, _table, _filters, _returning) do
    raise ArgumentError,
          "the ClickHouse adapter does not support DELETE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... DELETE` statement, not a synchronous SQL " <>
            "DELETE, so delete/4 is unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @doc false
  def explain_query(conn, query_string, params, opts) do
    Connection.query(conn, ["EXPLAIN ", query_string], params, opts)
  end
end
