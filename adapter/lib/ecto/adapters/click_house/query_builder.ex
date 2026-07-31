defmodule Ecto.Adapters.ClickHouse.QueryBuilder do
  @moduledoc """
  Statement generators for `Ecto.Adapters.SQL.Connection`: `all/2`,
  `update_all/2`, `delete_all/1`, `insert/8`, `update/5`, `delete/5`, and
  `explain_query/4`. These change for entirely different reasons than the
  expression/clause rendering in `Ecto.Adapters.ClickHouse.Expression` --
  e.g. adding an `expr/3` clause for a new Ecto fragment has nothing to do
  with `insert/8`'s on-conflict handling -- so they're kept apart.
  """

  alias Ecto.Adapters.ClickHouse.{Connection, Expression, Naming}

  @doc false
  def all(query, as_prefix \\ []) do
    sources = Naming.create_names(query, as_prefix)

    from = Expression.from(query, sources)
    select = Expression.select(query, sources)
    join = Expression.join(query, sources)
    where = Expression.where(query, sources)
    order_by = Expression.order_by(query, sources)
    limit = Expression.limit(query, sources)
    offset = Expression.offset(query, sources)

    unless query.group_bys == [] and query.havings == [] do
      Naming.error!(query, "the ClickHouse adapter does not support GROUP BY/HAVING yet")
    end

    unless query.windows == [] and query.combinations == [] do
      Naming.error!(query, "the ClickHouse adapter does not support windows/set operations yet")
    end

    [select, from, join, where, order_by, limit, offset]
  end

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
  ## what's needed to make `Ecto.Migration.SchemaMigration.down/4`'s
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
