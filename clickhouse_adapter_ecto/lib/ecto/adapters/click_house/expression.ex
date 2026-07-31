defmodule Ecto.Adapters.ClickHouse.Expression do
  @moduledoc """
  Clause and expression rendering for `SELECT` statements: `SELECT`,
  `FROM`, `JOIN`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`,
  `LIMIT`/`OFFSET`, and `expr/3`, the general Ecto expression renderer
  (literals, functions, operators, fragments).

  ## Joins

  `:inner`, `:left`, `:right`, `:full`, and `:cross` are supported --
  everything `join/4,5` and association-based `join: assoc(...)` queries
  can produce, other than ClickHouse-specific ASOF/semi/anti/lateral joins
  and `hints:`, which raise rather than being silently mishandled.

  Unlike Postgres/MySQL, a plain ClickHouse `LEFT JOIN` fills an unmatched
  right side with each column's type default (`""` for `String`, `0` for
  numeric types), not SQL `NULL`, unless the server has
  `join_use_nulls = 1` set. Code relying on `is_nil/1` against a
  left-joined column should account for this.

  ## What's not supported

  `DISTINCT`, selecting an entire source without an explicit field list,
  window functions, set operations (`union`, etc), `filter/2`
  (`Ecto.Query.API` documents it as Postgres-only), and any `ORDER BY`
  direction other than `:asc`/`:desc` all raise a clear
  `Ecto.QueryError` rather than being silently mishandled.
  """

  alias Ecto.Query.{BooleanExpr, ByExpr, JoinExpr, QueryExpr}
  alias Ecto.Adapters.ClickHouse.Naming

  @doc false
  def select(%{select: %{fields: fields}, distinct: distinct} = query, sources) do
    if distinct do
      Naming.error!(query, "the ClickHouse adapter does not support DISTINCT yet")
    end

    ["SELECT " | select_fields(fields, sources, query)]
  end

  @doc false
  def select_fields([], _sources, _query), do: "1"

  def select_fields(fields, sources, query) do
    Enum.map_intersperse(fields, ", ", fn
      {:&, _, [_idx]} ->
        Naming.error!(
          query,
          "the ClickHouse adapter does not support selecting an entire source without an " <>
            "explicit field list -- select the fields you need instead"
        )

      {key, value} ->
        [expr(value, sources, query), " AS ", Naming.quote_name(key)]

      value ->
        expr(value, sources, query)
    end)
  end

  @doc false
  def from(_query, sources) do
    {from_sql, name, _schema} = elem(sources, 0)
    [" FROM ", from_sql, " AS ", name]
  end

  ## `JOIN` -- `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS JOIN` on an explicit
  ## `ON` condition are supported (the common case for `Ecto.Query`'s
  ## `join/4,5` and association-based `join: assoc(...)` queries).
  ## ClickHouse's ANSI-style joins need no `ALL`/`ANY` strictness qualifier
  ## for a plain equality `ON` condition against the pinned
  ## `clickhouse/clickhouse-server:26.7` image used by this repo's
  ## `docker-compose.yml` -- ClickHouse defaults to `ALL` semantics (every
  ## matching row pairing, standard SQL join behaviour) unless a stricter
  ## `join_default_strictness` setting or an explicit `ANY`/`ASOF`/`SEMI`
  ## qualifier says otherwise, so the generated SQL stays exactly the
  ## standard-SQL shape other Ecto adapters (Postgres, MyXQL) produce
  ## instead of ClickHouse-specific syntax. `CROSS JOIN` never gets an `ON`
  ## clause, matching every other Ecto SQL adapter -- see `join_on/4`.
  ##
  ## Explicitly out of scope (raise instead of silently mishandling):
  ##
  ##   * Any ClickHouse-specific ASOF/semi/anti/lateral/array join, which
  ##     Ecto surfaces via `qual:` values this adapter doesn't recognize --
  ##     can be added later if needed, but nothing here maps a `qual` to
  ##     them today.
  ##   * `hints:` (Ecto's `join/5` `hints:` option) -- there is no
  ##     ClickHouse-specific hint support (e.g. `ANY`/`ASOF` strictness,
  ##     join algorithm hints) implemented, so any join with hints raises
  ##     rather than silently dropping them.
  ##
  ## One real dialect difference this does *not* try to paper over: unlike
  ## Postgres/MySQL, a plain ClickHouse `LEFT JOIN` fills an unmatched right
  ## side with each column's *type default* (`""` for `String`, `0` for
  ## numeric types, etc.), not SQL `NULL`, unless the server has
  ## `join_use_nulls = 1` set (off by default) and the column is
  ## `Nullable(...)`. Callers relying on `is_nil/1` against a left-joined
  ## column should account for this.
  @doc false
  def join(%{joins: []}, _sources), do: []

  def join(%{joins: joins} = query, sources) do
    Enum.map(joins, &join_expr(&1, sources, query))
  end

  defp join_expr(%JoinExpr{hints: [_ | _] = hints}, _sources, query) do
    Naming.error!(
      query,
      "the ClickHouse adapter does not support join hints yet (got #{inspect(hints)})"
    )
  end

  defp join_expr(%JoinExpr{qual: qual, ix: ix, on: %QueryExpr{expr: on_expr}}, sources, query) do
    {source_sql, name, _schema} = elem(sources, ix)

    [
      join_qual(qual, query),
      source_sql,
      " AS ",
      name
      | join_on(qual, on_expr, sources, query)
    ]
  end

  # CROSS JOIN takes no ON clause -- Ecto still gives every join an `on:`
  # QueryExpr, defaulting to the literal `true` when the caller didn't
  # write one, so drop it here rather than emit "CROSS JOIN t AS a ON true"
  # (harmless on ClickHouse, but not what a plain `join(:cross, ...)` with
  # no `on:` should produce). A caller who *does* write a real `on:`
  # condition on a cross join still gets it rendered, same as every other
  # qualifier.
  defp join_on(:cross, true, _sources, _query), do: []
  defp join_on(_qual, on_expr, sources, query), do: [" ON ", expr(on_expr, sources, query)]

  defp join_qual(:inner, _query), do: " INNER JOIN "
  defp join_qual(:left, _query), do: " LEFT JOIN "
  defp join_qual(:right, _query), do: " RIGHT JOIN "
  defp join_qual(:full, _query), do: " FULL JOIN "
  defp join_qual(:cross, _query), do: " CROSS JOIN "

  defp join_qual(qual, query) do
    Naming.error!(
      query,
      "the ClickHouse adapter only supports :inner, :left, :right, :full, and :cross joins " <>
        "(got #{inspect(qual)}) -- ClickHouse-specific ASOF/semi/anti/lateral joins are not " <>
        "implemented"
    )
  end

  @doc false
  def where(%{wheres: []}, _sources), do: []

  def where(%{wheres: wheres} = query, sources) do
    boolean(" WHERE ", wheres, sources, query)
  end

  ## `GROUP BY` -- one or more grouping columns/expressions, comma-separated.
  ## Structurally the same shape `order_by/2` already handles (a
  ## `%Ecto.Query.ByExpr{}` per `group_by(...)` call, each wrapping a list of
  ## expressions), minus the `{direction, expr}` wrapper `ORDER BY` has --
  ## `group_by/3` has no notion of ascending/descending, so each element of
  ## `expr` is rendered directly through the shared `expr/3` renderer.
  ##
  ## Explicitly out of scope (raise instead of silently mishandling):
  ##
  ##   * SQL-standard `GROUPING SETS`/`ROLLUP`/`CUBE` -- Ecto's `group_by/3`
  ##     doesn't expose a way to express these at all, so there is nothing
  ##     for this function to reject; they simply can't reach it.
  ##   * ClickHouse's own `GROUP BY ... WITH TOTALS`/`WITH ROLLUP`/`WITH CUBE`
  ##     modifiers -- same story, no `Ecto.Query` construct maps to them, and
  ##     nothing here tries to synthesize ClickHouse-specific syntax that
  ##     Ecto's query API doesn't ask for.
  @doc false
  def group_by(%{group_bys: []}, _sources), do: []

  def group_by(%{group_bys: group_bys} = query, sources) do
    [
      " GROUP BY "
      | Enum.map_intersperse(group_bys, ", ", fn %ByExpr{expr: expr} ->
          Enum.map_intersperse(expr, ", ", &expr(&1, sources, query))
        end)
    ]
  end

  ## `HAVING` -- a boolean condition over the grouped/aggregated result,
  ## rendered with exactly the same `boolean/4` clause-composition machinery
  ## `where/2` already uses: `HAVING`'s condition is the same kind of
  ## `%Ecto.Query.BooleanExpr{}` tree `WHERE` gets, just evaluated after
  ## `GROUP BY` instead of before it, so there is no ClickHouse-specific
  ## dialect difference to account for here.
  @doc false
  def having(%{havings: []}, _sources), do: []

  def having(%{havings: havings} = query, sources) do
    boolean(" HAVING ", havings, sources, query)
  end

  @doc false
  def order_by(%{order_bys: []}, _sources), do: []

  def order_by(%{order_bys: order_bys} = query, sources) do
    [
      " ORDER BY "
      | Enum.map_intersperse(order_bys, ", ", fn %ByExpr{expr: expr} ->
          Enum.map_intersperse(expr, ", ", &order_by_expr(&1, sources, query))
        end)
    ]
  end

  defp order_by_expr({dir, expr}, sources, query) do
    str = expr(expr, sources, query)

    case dir do
      :asc -> str
      :desc -> [str | " DESC"]
      _ -> Naming.error!(query, "#{dir} is not supported in ORDER BY by the ClickHouse adapter")
    end
  end

  @doc false
  def limit(%{limit: nil}, _sources), do: []

  def limit(%{limit: %{expr: expr}} = query, sources) do
    [" LIMIT " | expr(expr, sources, query)]
  end

  @doc false
  def offset(%{offset: nil}, _sources), do: []

  def offset(%{offset: %QueryExpr{expr: expr}} = query, sources) do
    [" OFFSET " | expr(expr, sources, query)]
  end

  @doc false
  def boolean(_name, [], _sources, _query), do: []

  def boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
    [
      name,
      Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
        %BooleanExpr{expr: expr, op: op}, {op, acc} ->
          {op, [acc, operator_to_boolean(op) | paren_expr(expr, sources, query)]}

        %BooleanExpr{expr: expr, op: op}, {_, acc} ->
          {op, [?(, acc, ?), operator_to_boolean(op) | paren_expr(expr, sources, query)]}
      end)
      |> elem(1)
    ]
  end

  defp operator_to_boolean(:and), do: " AND "
  defp operator_to_boolean(:or), do: " OR "

  @doc false
  def paren_expr(expr, sources, query) do
    [?(, expr(expr, sources, query), ?)]
  end

  binary_ops = [
    ==: " = ",
    !=: " != ",
    <=: " <= ",
    >=: " >= ",
    <: " < ",
    >: " > ",
    +: " + ",
    -: " - ",
    *: " * ",
    /: " / ",
    and: " AND ",
    or: " OR ",
    like: " LIKE "
  ]

  @binary_ops Keyword.keys(binary_ops)

  Enum.map(binary_ops, fn {op, str} ->
    defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
  end)

  defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

  @doc false
  def expr({:^, [], [_ix]}, _sources, _query), do: "?"

  def expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query)
      when is_atom(field) or is_binary(field) do
    case elem(sources, idx) do
      # Empty alias (used by `QueryBuilder.delete_all/1`'s `ALTER TABLE ... DELETE`,
      # which has no `FROM ... AS alias` to qualify against) -> emit a bare
      # unqualified column name instead of `<alias>.<column>`.
      {_, "", _schema} -> Naming.quote_name(field)
      {_, name, _schema} -> [name, ?. | Naming.quote_name(field)]
    end
  end

  def expr({:&, _, [idx]}, sources, _query) do
    {_, name, _schema} = elem(sources, idx)
    name
  end

  def expr({:is_nil, _, [arg]}, sources, query) do
    [expr(arg, sources, query) | " IS NULL"]
  end

  def expr({:not, _, [{:is_nil, _, [arg]}]}, sources, query) do
    [expr(arg, sources, query) | " IS NOT NULL"]
  end

  def expr({:not, _, [expr]}, sources, query) do
    ["NOT (", expr(expr, sources, query), ?)]
  end

  def expr({:in, _, [_left, []]}, _sources, _query), do: "0"

  def expr({:in, _, [left, right]}, sources, query) when is_list(right) do
    args = Enum.map_intersperse(right, ?,, &expr(&1, sources, query))
    [expr(left, sources, query), " IN (", args, ?)]
  end

  def expr({:in, _, [_, {:^, _, [_, 0]}]}, _sources, _query), do: "0"

  def expr({:in, _, [left, {:^, _, [_, length]}]}, sources, query) do
    args = Enum.intersperse(List.duplicate("?", length), ?,)
    [expr(left, sources, query), " IN (", args, ?)]
  end

  def expr({:count, _, []}, _sources, _query), do: "count(*)"

  # `count(field, :distinct)` -- the arity-2 form of `Ecto.Query.API.count/2`
  # -- doesn't map onto the generic `{fun, _, args}` function-call clause
  # below: that clause would try to render `:distinct` itself through
  # `expr/3` as if it were a fourth SQL argument (`count(field, :distinct)`
  # literally, or worse, an "unsupported expression" error for the bare
  # atom), instead of the `count(DISTINCT field)` syntax it actually means.
  # `sum`/`avg`/`min`/`max`/plain `count(field)` all stay on the generic
  # clause below unchanged -- they're ordinary single-argument function
  # calls ClickHouse's function names line up with directly.
  def expr({:count, _, [field, :distinct]}, sources, query) do
    ["count(DISTINCT ", expr(field, sources, query), ?)]
  end

  # `Ecto.Query.API.filter/2` (`FILTER` applied to an aggregate) is
  # documented by Ecto itself as Postgres-only. Left to the generic
  # `{fun, _, args}` clause below, `:filter` would be treated as an ordinary
  # function name and rendered as `filter(agg, cond)`, which is not valid
  # ClickHouse syntax (Postgres's `agg(...) FILTER (WHERE cond)` is a
  # different clause shape entirely, not a function call) -- silently wrong
  # SQL instead of a clear error. Reject it explicitly instead.
  def expr({:filter, _, [_value, _filter]}, _sources, query) do
    Naming.error!(
      query,
      "the ClickHouse adapter does not support filter/2 -- Ecto documents FILTER-on-aggregate " <>
        "as Postgres-only, and it has no ClickHouse equivalent this adapter renders"
    )
  end

  def expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args
        [paren_if_needed(left, sources, query), op | paren_if_needed(right, sources, query)]

      {:fun, fun} ->
        [fun, ?(, Enum.map_intersperse(args, ", ", &expr(&1, sources, query)), ?)]
    end
  end

  def expr(%Decimal{} = decimal, _sources, _query), do: Decimal.to_string(decimal, :normal)

  def expr(%Ecto.Query.Tagged{value: value}, sources, query), do: expr(value, sources, query)

  def expr(nil, _sources, _query), do: "NULL"
  def expr(true, _sources, _query), do: "1"
  def expr(false, _sources, _query), do: "0"

  def expr(literal, _sources, _query) when is_binary(literal) do
    ChDriver.Params.quote_param_value(literal, 1)
  end

  def expr(literal, _sources, _query) when is_integer(literal), do: Integer.to_string(literal)
  def expr(literal, _sources, _query) when is_float(literal), do: Float.to_string(literal)

  def expr(%NaiveDateTime{} = ndt, _sources, _query), do: [?', NaiveDateTime.to_string(ndt), ?']
  def expr(%DateTime{} = dt, _sources, _query), do: [?', DateTime.to_string(dt), ?']
  def expr(%Date{} = d, _sources, _query), do: [?', Date.to_string(d), ?']

  def expr(expr, _sources, query) do
    Naming.error!(query, "unsupported expression for the ClickHouse adapter: #{inspect(expr)}")
  end

  defp paren_if_needed({op, _, [_, _]} = expr, sources, query) when op in @binary_ops do
    paren_expr(expr, sources, query)
  end

  defp paren_if_needed(expr, sources, query), do: expr(expr, sources, query)
end
