defmodule Ecto.Adapters.ClickHouse.Expression do
  @moduledoc """
  Clause and expression renderers used by `Ecto.Adapters.ClickHouse.QueryBuilder`
  to build SELECT statements: `SELECT`, `FROM`, `WHERE`, `ORDER BY`,
  `LIMIT`/`OFFSET`, boolean composition, and the `expr/3` Ecto expression
  renderer (with its many clauses covering literals, functions, operators,
  and fragments). This is the file that grows every time a new Ecto
  fragment or operator is supported, so it stays focused purely on that.
  """

  alias Ecto.Query.{BooleanExpr, ByExpr, QueryExpr}
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

  @doc false
  def where(%{wheres: []}, _sources), do: []

  def where(%{wheres: wheres} = query, sources) do
    boolean(" WHERE ", wheres, sources, query)
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
