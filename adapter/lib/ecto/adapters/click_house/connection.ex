defmodule Ecto.Adapters.ClickHouse.Connection do
  @moduledoc """
  Implements `Ecto.Adapters.SQL.Connection` on top of `ChDriver`.

  ## Parameter binding

  SQL is generated the normal Ecto way with `?` placeholders (see
  `expr/3`, `insert/8`), matching every other `Ecto.Adapters.SQL.Connection`
  implementation. Rather than inlining the corresponding runtime values as
  SQL literals, `bind_params/2` rewrites each `?` into a ClickHouse native
  `{pN:Type}` parameter placeholder and sends the actual value alongside
  the query through `ChDriver`'s query-parameters wire mechanism (see
  `ChDriver.Protocol.encode_query/2`) -- the value's bytes never pass
  through the SQL text at all, so there's nothing to escape and no `?`
  inside a string literal or raw fragment can be mistaken for a bind
  placeholder (`bind_params/2` tracks quoted regions while scanning).

  ClickHouse's parameter mechanism has no type-independent way to express
  NULL (see `ChDriver.Params.text/1`), so a `nil` value is the one
  exception: it's inlined directly as the literal `NULL` token, which
  carries no injection risk since it's a fixed constant.
  """

  @behaviour Ecto.Adapters.SQL.Connection

  alias Ecto.Query.{BooleanExpr, ByExpr, QueryExpr}

  ## Connection

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(ChDriver.DBConnection, opts)
  end

  ## Query execution

  @impl true
  def prepare_execute(conn, _name, sql, params, opts) do
    statement = IO.iodata_to_binary(sql)
    {final_sql, wire_params} = bind_params(statement, params)

    case ChDriver.query(conn, final_sql, wire_params, opts) do
      {:ok, result} -> {:ok, %ChDriver.Query{statement: statement}, to_sql_result(result)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def execute(conn, %ChDriver.Query{statement: statement}, params, opts) do
    {final_sql, wire_params} = bind_params(statement, params)

    case ChDriver.query(conn, final_sql, wire_params, opts) do
      {:ok, result} -> {:ok, to_sql_result(result)}
      {:error, _} = error -> error
    end
  end

  def execute(conn, statement, params, opts) when is_binary(statement) do
    execute(conn, %ChDriver.Query{statement: statement}, params, opts)
  end

  @impl true
  def query(conn, statement, params, opts) do
    {final_sql, wire_params} = bind_params(IO.iodata_to_binary(statement), params)

    case ChDriver.query(conn, final_sql, wire_params, opts) do
      {:ok, result} -> {:ok, to_sql_result(result)}
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

  ## Parameter binding

  @doc false
  def bind_params(sql, params) do
    chunks = scan_placeholders(sql)
    placeholder_count = Enum.count(chunks, &(&1 == :placeholder))

    if placeholder_count != length(params) do
      raise ArgumentError,
            "expected #{placeholder_count} params in statement #{inspect(sql)}, got " <>
              "#{length(params)}"
    end

    {sql_iodata, wire_params} = do_bind(chunks, params, [], [], 0)
    {IO.iodata_to_binary(sql_iodata), wire_params}
  end

  defp do_bind([], [], sql_acc, wire_acc, _ix) do
    {Enum.reverse(sql_acc), Enum.reverse(wire_acc)}
  end

  defp do_bind([text | rest], params, sql_acc, wire_acc, ix) when is_binary(text) do
    do_bind(rest, params, [text | sql_acc], wire_acc, ix)
  end

  defp do_bind([:placeholder | rest], [nil | params_rest], sql_acc, wire_acc, ix) do
    do_bind(rest, params_rest, ["NULL" | sql_acc], wire_acc, ix + 1)
  end

  defp do_bind([:placeholder | rest], [value | params_rest], sql_acc, wire_acc, ix) do
    name = "p#{ix}"
    {type, raw_text, rounds} = ChDriver.Params.encode(value)
    placeholder = ["{", name, ":", type, "}"]
    wire_param = {name, raw_text, rounds}
    do_bind(rest, params_rest, [placeholder | sql_acc], [wire_param | wire_acc], ix + 1)
  end

  # Scans `sql` for `?` placeholders, tracking single/double-quoted regions
  # so a literal `?` inside a string literal or quoted identifier (e.g. a
  # raw fragment's own text, or a `LIKE` pattern written directly in the
  # query) is never mistaken for a bind position. Returns an alternating
  # list of text chunks (binaries) and `:placeholder` markers.
  defp scan_placeholders(sql) when is_binary(sql), do: scan_placeholders(sql, [], <<>>)

  defp scan_placeholders(<<>>, acc, buf), do: Enum.reverse([buf | acc])

  defp scan_placeholders(<<"?", rest::binary>>, acc, buf) do
    scan_placeholders(rest, [:placeholder, buf | acc], <<>>)
  end

  defp scan_placeholders(<<"'", rest::binary>>, acc, buf) do
    {quoted, rest} = consume_quoted(rest, ?', <<"'">>)
    scan_placeholders(rest, acc, <<buf::binary, quoted::binary>>)
  end

  defp scan_placeholders(<<"\"", rest::binary>>, acc, buf) do
    {quoted, rest} = consume_quoted(rest, ?", <<"\"">>)
    scan_placeholders(rest, acc, <<buf::binary, quoted::binary>>)
  end

  defp scan_placeholders(<<byte, rest::binary>>, acc, buf) do
    scan_placeholders(rest, acc, <<buf::binary, byte>>)
  end

  # `q` is the terminating quote byte (`?'` or `?"`); backslash-escapes are
  # honored the same way ClickHouse itself parses them (see
  # `ChDriver.Params.quote_param_value/2`) so an escaped quote never ends
  # the region early.
  defp consume_quoted(<<"\\", c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, "\\", c>>)
  end

  defp consume_quoted(<<c, rest::binary>>, q, acc) when c == q, do: {<<acc::binary, c>>, rest}

  defp consume_quoted(<<c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, c>>)
  end

  defp consume_quoted(<<>>, _q, acc), do: {acc, <<>>}

  ## Query generation (SELECT)

  @impl true
  def all(query, as_prefix \\ []) do
    sources = create_names(query, as_prefix)

    from = from(query, sources)
    select = select(query, sources)
    where = where(query, sources)
    order_by = order_by(query, sources)
    limit = limit(query, sources)
    offset = offset(query, sources)

    unless query.joins == [] do
      error!(query, "the ClickHouse adapter does not support joins yet")
    end

    unless query.group_bys == [] and query.havings == [] do
      error!(query, "the ClickHouse adapter does not support GROUP BY/HAVING yet")
    end

    unless query.windows == [] and query.combinations == [] do
      error!(query, "the ClickHouse adapter does not support windows/set operations yet")
    end

    [select, from, where, order_by, limit, offset]
  end

  @impl true
  def update_all(query, _prefix \\ nil) do
    error!(
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
  @impl true
  def delete_all(%{sources: sources} = query) do
    unless query.joins == [] do
      error!(query, "the ClickHouse adapter does not support joins in delete_all/2")
    end

    unless query.limit == nil and query.offset == nil do
      error!(
        query,
        "the ClickHouse adapter does not support LIMIT/OFFSET in delete_all/2 -- " <>
          "ClickHouse's `ALTER TABLE ... DELETE` mutation only accepts a WHERE clause"
      )
    end

    unless tuple_size(sources) == 1 do
      error!(query, "the ClickHouse adapter only supports delete_all/1 against a single source")
    end

    # Unlike `all/2`, `ALTER TABLE ... DELETE` has no `FROM ... AS alias`
    # clause to declare a table alias against -- it's always exactly one
    # bare table name. Build a one-element sources tuple with an empty
    # alias so `where/2`/`expr/3` emit unqualified `"version"` instead of
    # `s0."version"` (which ClickHouse would reject: "Missing columns:
    # 's0.version'" -- there's no `s0` in scope here).
    {table, schema, prefix} = elem(sources, 0)
    table_sql = quote_table(prefix, table)
    delete_sources = {{table_sql, "", schema}}

    # `ALTER TABLE ... DELETE` requires a WHERE clause (unlike a plain SQL
    # DELETE, ClickHouse has no unconditional-delete-everything form of the
    # mutation) -- `where/2` returns `[]` when the query has no `where(...)`
    # at all, so fall back to an always-true condition to delete every row,
    # matching `Repo.delete_all(query)` semantics with no filter.
    where_clause =
      case query.wheres do
        [] -> " WHERE 1"
        _ -> where(query, delete_sources)
      end

    [
      "ALTER TABLE ",
      table_sql,
      " DELETE",
      where_clause,
      " SETTINGS mutations_sync = 1"
    ]
  end

  @impl true
  def insert(prefix, table, header, rows, on_conflict, returning, placeholders, _opts \\ [])

  def insert(_prefix, _table, _header, _rows, _on_conflict, [_ | _], _placeholders, _opts) do
    raise ArgumentError,
          "the ClickHouse adapter does not support :returning -- ClickHouse's INSERT has no " <>
            "RETURNING clause"
  end

  def insert(prefix, table, header, rows, {:raise, _, []}, [], placeholders, _opts) do
    fields = quote_names(header)

    [
      "INSERT INTO ",
      quote_table(prefix, table),
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
  @impl true
  def update(_prefix, _table, _fields, _filters, _returning) do
    raise ArgumentError,
          "the ClickHouse adapter does not support UPDATE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... UPDATE` statement, not a synchronous SQL " <>
            "UPDATE, so update/5 is unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @impl true
  def delete(_prefix, _table, _filters, _returning) do
    raise ArgumentError,
          "the ClickHouse adapter does not support DELETE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... DELETE` statement, not a synchronous SQL " <>
            "DELETE, so delete/4 is unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @impl true
  def explain_query(conn, query_string, params, opts) do
    query(conn, ["EXPLAIN ", query_string], params, opts)
  end

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

  ## Expression building

  defp select(%{select: %{fields: fields}, distinct: distinct} = query, sources) do
    if distinct do
      error!(query, "the ClickHouse adapter does not support DISTINCT yet")
    end

    ["SELECT " | select_fields(fields, sources, query)]
  end

  defp select_fields([], _sources, _query), do: "1"

  defp select_fields(fields, sources, query) do
    Enum.map_intersperse(fields, ", ", fn
      {:&, _, [_idx]} ->
        error!(
          query,
          "the ClickHouse adapter does not support selecting an entire source without an " <>
            "explicit field list -- select the fields you need instead"
        )

      {key, value} ->
        [expr(value, sources, query), " AS ", quote_name(key)]

      value ->
        expr(value, sources, query)
    end)
  end

  defp from(_query, sources) do
    {from_sql, name, _schema} = elem(sources, 0)
    [" FROM ", from_sql, " AS ", name]
  end

  defp where(%{wheres: []}, _sources), do: []

  defp where(%{wheres: wheres} = query, sources) do
    boolean(" WHERE ", wheres, sources, query)
  end

  defp order_by(%{order_bys: []}, _sources), do: []

  defp order_by(%{order_bys: order_bys} = query, sources) do
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
      _ -> error!(query, "#{dir} is not supported in ORDER BY by the ClickHouse adapter")
    end
  end

  defp limit(%{limit: nil}, _sources), do: []

  defp limit(%{limit: %{expr: expr}} = query, sources) do
    [" LIMIT " | expr(expr, sources, query)]
  end

  defp offset(%{offset: nil}, _sources), do: []

  defp offset(%{offset: %QueryExpr{expr: expr}} = query, sources) do
    [" OFFSET " | expr(expr, sources, query)]
  end

  defp boolean(_name, [], _sources, _query), do: []

  defp boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
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

  defp paren_expr(expr, sources, query) do
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

  defp expr({:^, [], [_ix]}, _sources, _query), do: "?"

  defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query)
       when is_atom(field) or is_binary(field) do
    case elem(sources, idx) do
      # Empty alias (used by `delete_all/1`'s `ALTER TABLE ... DELETE`,
      # which has no `FROM ... AS alias` to qualify against) -> emit a bare
      # unqualified column name instead of `<alias>.<column>`.
      {_, "", _schema} -> quote_name(field)
      {_, name, _schema} -> [name, ?. | quote_name(field)]
    end
  end

  defp expr({:&, _, [idx]}, sources, _query) do
    {_, name, _schema} = elem(sources, idx)
    name
  end

  defp expr({:is_nil, _, [arg]}, sources, query) do
    [expr(arg, sources, query) | " IS NULL"]
  end

  defp expr({:not, _, [{:is_nil, _, [arg]}]}, sources, query) do
    [expr(arg, sources, query) | " IS NOT NULL"]
  end

  defp expr({:not, _, [expr]}, sources, query) do
    ["NOT (", expr(expr, sources, query), ?)]
  end

  defp expr({:in, _, [_left, []]}, _sources, _query), do: "0"

  defp expr({:in, _, [left, right]}, sources, query) when is_list(right) do
    args = Enum.map_intersperse(right, ?,, &expr(&1, sources, query))
    [expr(left, sources, query), " IN (", args, ?)]
  end

  defp expr({:in, _, [_, {:^, _, [_, 0]}]}, _sources, _query), do: "0"

  defp expr({:in, _, [left, {:^, _, [_, length]}]}, sources, query) do
    args = Enum.intersperse(List.duplicate("?", length), ?,)
    [expr(left, sources, query), " IN (", args, ?)]
  end

  defp expr({:count, _, []}, _sources, _query), do: "count(*)"

  defp expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args
        [paren_if_needed(left, sources, query), op | paren_if_needed(right, sources, query)]

      {:fun, fun} ->
        [fun, ?(, Enum.map_intersperse(args, ", ", &expr(&1, sources, query)), ?)]
    end
  end

  defp expr(%Decimal{} = decimal, _sources, _query), do: Decimal.to_string(decimal, :normal)

  defp expr(%Ecto.Query.Tagged{value: value}, sources, query), do: expr(value, sources, query)

  defp expr(nil, _sources, _query), do: "NULL"
  defp expr(true, _sources, _query), do: "1"
  defp expr(false, _sources, _query), do: "0"

  defp expr(literal, _sources, _query) when is_binary(literal) do
    ChDriver.Params.quote_param_value(literal, 1)
  end

  defp expr(literal, _sources, _query) when is_integer(literal), do: Integer.to_string(literal)
  defp expr(literal, _sources, _query) when is_float(literal), do: Float.to_string(literal)

  defp expr(%NaiveDateTime{} = ndt, _sources, _query), do: [?', NaiveDateTime.to_string(ndt), ?']
  defp expr(%DateTime{} = dt, _sources, _query), do: [?', DateTime.to_string(dt), ?']
  defp expr(%Date{} = d, _sources, _query), do: [?', Date.to_string(d), ?']

  defp expr(expr, _sources, query) do
    error!(query, "unsupported expression for the ClickHouse adapter: #{inspect(expr)}")
  end

  defp paren_if_needed({op, _, [_, _]} = expr, sources, query) when op in @binary_ops do
    paren_expr(expr, sources, query)
  end

  defp paren_if_needed(expr, sources, query), do: expr(expr, sources, query)

  ## Naming helpers

  defp create_names(%{sources: sources}, as_prefix) do
    create_names(sources, 0, tuple_size(sources), as_prefix) |> List.to_tuple()
  end

  defp create_names(sources, pos, limit, as_prefix) when pos < limit do
    [create_name(sources, pos, as_prefix) | create_names(sources, pos + 1, limit, as_prefix)]
  end

  defp create_names(_sources, pos, pos, as_prefix), do: [as_prefix]

  defp create_name(sources, pos, as_prefix) do
    case elem(sources, pos) do
      {table, schema, prefix} ->
        name = as_prefix ++ [create_alias(table) | Integer.to_string(pos)]
        {quote_table(prefix, table), name, schema}

      %Ecto.SubQuery{} ->
        {nil, as_prefix ++ [?s | Integer.to_string(pos)], nil}
    end
  end

  defp create_alias(<<first, _rest::binary>>) when first in ?a..?z when first in ?A..?Z, do: first
  defp create_alias(_), do: ?t

  ## Quoting -- double quotes are
  ## accepted for identifiers (`SELECT "id" FROM "events"`); backticks work
  ## too, but double quotes are the ANSI-standard choice and match what the
  ## rest of the Ecto ecosystem (Postgres) expects, so that's what's used
  ## here. Single quotes remain reserved for string literals.
  ##
  ## `quote_name/1` and `quote_table/2` are exposed (rather than kept `defp`)
  ## so `Ecto.Adapters.ClickHouse.DDL`'s DDL generation can reuse the exact
  ## same identifier-quoting logic used here for SELECT/expression building,
  ## instead of duplicating it.

  @doc false
  def quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  def quote_name(name) when is_binary(name) do
    if String.contains?(name, "\"") do
      error!(nil, "bad literal/field/table name #{inspect(name)} (\" is not permitted)")
    end

    [?", name, ?"]
  end

  defp quote_names(names), do: Enum.map_intersperse(names, ?,, &quote_name/1)

  @doc false
  def quote_table(nil, name), do: quote_table(name)
  def quote_table(prefix, name), do: [quote_table(prefix), ?., quote_table(name)]

  defp quote_table(name) when is_atom(name), do: quote_table(Atom.to_string(name))

  defp quote_table(name) do
    if String.contains?(name, "\"") do
      error!(nil, "bad table name #{inspect(name)}")
    end

    [?", name, ?"]
  end

  defp error!(nil, message), do: raise(ArgumentError, message)
  defp error!(query, message), do: raise(Ecto.QueryError, query: query, message: message)
end

