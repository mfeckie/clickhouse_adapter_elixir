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

