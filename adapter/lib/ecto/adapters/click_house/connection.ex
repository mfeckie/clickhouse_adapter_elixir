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
  NULL (see `ChDriver.Protocol.param_text/1`), so a `nil` value is the one
  exception: it's inlined directly as the literal `NULL` token, which
  carries no injection risk since it's a fixed constant.
  """

  @behaviour Ecto.Adapters.SQL.Connection

  alias Ecto.Query.{BooleanExpr, ByExpr, QueryExpr}
  alias Ecto.Migration.{Reference, Table}

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
    placeholder = ["{", name, ":", param_type!(value), "}"]
    raw_text = ChDriver.Protocol.param_text(value)
    rounds = ChDriver.Protocol.escape_rounds(value)
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
  # honored the same way ClickHouse itself parses them (see `escape_string/1`)
  # so an escaped quote never ends the region early.
  defp consume_quoted(<<"\\", c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, "\\", c>>)
  end

  defp consume_quoted(<<c, rest::binary>>, q, acc) when c == q, do: {<<acc::binary, c>>, rest}

  defp consume_quoted(<<c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, c>>)
  end

  defp consume_quoted(<<>>, _q, acc), do: {acc, <<>>}

  # Maps an Elixir runtime value to the ClickHouse type name used in its
  # `{name:Type}` placeholder. There's no clause for `nil` -- `do_bind/5`
  # inlines it as a literal `NULL` before this is ever called, since no
  # single declared parameter type parses NULL correctly against every
  # column type it might be compared against (a `Nullable(String)` NULL
  # parameter fails to bind against an `Int32` column with "Attempt to
  # read after eof... while converting '' to Int32").
  defp param_type!(b) when is_binary(b), do: "String"
  defp param_type!(i) when is_integer(i), do: "Int64"
  defp param_type!(f) when is_float(f), do: "Float64"
  defp param_type!(bool) when is_boolean(bool), do: "UInt8"
  defp param_type!(%Decimal{}), do: "String"
  defp param_type!(%Date{}), do: "Date"
  defp param_type!(%NaiveDateTime{}), do: "DateTime"
  defp param_type!(%DateTime{}), do: "DateTime"
  defp param_type!([]), do: "Array(String)"
  defp param_type!([head | _]), do: "Array(#{param_type!(head)})"

  defp param_type!(other) do
    raise ArgumentError,
          "the ClickHouse adapter does not know how to bind #{inspect(other)} as a query " <>
            "parameter"
  end

  # ClickHouse string literals use backslash escaping (like MySQL):
  # `SELECT 'it''s'` fails while `SELECT 'it\'s'` and doubled
  # backslashes round-trip correctly. Used for the handful of literal
  # constants `expr/3` writes directly into the query text (values that
  # come from the query definition itself, not a runtime `^` param).
  defp escape_string(value) do
    value
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("'", "\\'", [:global])
  end

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
        "so update_all/2 is deliberately unimplemented -- issue an ALTER TABLE mutation " <>
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
  ## query returns -- confirmed live against ClickHouse 24.8. That's exactly
  ## what's needed to make `Ecto.Migration.SchemaMigration.down/4`'s
  ## `repo.delete_all(from m in "schema_migrations", where: m.version == ^v)`
  ## behave synchronously enough for `Ecto.Migrator.run(repo, path, :down,
  ## ...)` to work: insert the row (`up`), delete it and immediately have it
  ## gone (`down`), no polling or manual mutation-tracking required.
  ##
  ## This is genuinely a mutation under the hood, not a real transactional
  ## DELETE, so the scope here is deliberately narrow to what maps cleanly
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
    # 's0.version'", confirmed live -- there's no `s0` in scope here).
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
            "UPDATE, so update/5 is deliberately unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @impl true
  def delete(_prefix, _table, _filters, _returning) do
    raise ArgumentError,
          "the ClickHouse adapter does not support DELETE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... DELETE` statement, not a synchronous SQL " <>
            "DELETE, so delete/4 is deliberately unimplemented -- issue an ALTER TABLE " <>
            "mutation directly via a raw query if you need this"
  end

  @impl true
  def explain_query(conn, query_string, params, opts) do
    query(conn, ["EXPLAIN ", query_string], params, opts)
  end

  ## DDL
  ##
  ## Only `CREATE TABLE [IF NOT EXISTS]` (from `Ecto.Migration.Table` + a
  ## column list of plain `{:add, name, type, opts}` commands) and
  ## `DROP TABLE [IF EXISTS]` are implemented -- enough to let
  ## `Ecto.Migration.SchemaMigration.ensure_schema_migrations_table!/3`
  ## (called internally by `Ecto.Migrator`) create the `schema_migrations`
  ## table, and for a migration author's own `create table(...)` /
  ## `drop table(...)` to work for simple, single-statement tables.
  ##
  ## `:alter` (adding/removing/modifying columns on an existing table),
  ## indexes, and constraints are NOT implemented -- ClickHouse's ALTER TABLE
  ## semantics (async mutations, `ADD COLUMN`/`MODIFY COLUMN` quirks per
  ## engine) don't map cleanly onto `Ecto.Migration.Table`'s `:alter`
  ## subcommands, and ClickHouse has no unique/foreign-key constraints at
  ## all. Use a raw SQL string via `execute/1` in a migration for anything
  ## beyond a one-shot `CREATE`/`DROP TABLE`.
  ##
  ## ## Which DDL is safe for `change/0` auto-reversal, and which isn't
  ##
  ## Ecto's `change/0` migrations rely on `Ecto.Migration`'s built-in
  ## reversal (`create table(...)` -> `drop table(...)`, `add :col, :type` ->
  ## `remove :col`, etc) to synthesize the `down` direction for you. Whether
  ## that's *safe* to auto-generate for ClickHouse specifically depends on
  ## whether the underlying operation is synchronous/metadata-only or an
  ## asynchronous, potentially-lossy rewrite:
  ##
  ##   SAFE for `change/0` (synchronous, metadata-only, reverses cleanly):
  ##     * `create table(...)` / `drop table(...)` -- implemented here.
  ##     * `add :col, :type` / `remove :col` -- ClickHouse's
  ##       `ALTER TABLE ... ADD COLUMN` / `DROP COLUMN` are synchronous
  ##       metadata changes (no data rewrite), same category as `CREATE`/
  ##       `DROP TABLE`. **Not yet implemented in this adapter** (`:alter` is
  ##       rejected below) -- conceptually safe to auto-reverse, just not
  ##       built yet; use raw `execute/1` SQL for both directions until it is.
  ##
  ##   UNSAFE -- require explicit `up/0` + `down/0`, never `change/0`:
  ##     * `ALTER TABLE ... MODIFY ORDER BY` / partition key changes --
  ##       MergeTree's ORDER BY/PARTITION BY defines the on-disk sort order
  ##       and physically reorganizes existing parts; there is no generic
  ##       "undo" (the old physical layout isn't recoverable from the new
  ##       one), and Ecto has no built-in reversal for this operation anyway.
  ##     * `ALTER TABLE ... MODIFY COLUMN <type>` (a real type change, not a
  ##       widening no-op) -- this triggers an asynchronous background
  ##       mutation that rewrites every existing part; data can be
  ##       irreversibly truncated/coerced during the rewrite (e.g. String ->
  ##       Int32 on non-numeric values), so "reversing" it by mutating back
  ##       to the old type does not restore the original bytes.
  ##     * Any `UPDATE`/`DELETE`-shaped mutation on existing rows
  ##       (`ALTER TABLE ... UPDATE/DELETE`, see `update_all/2` and the
  ##       narrowly-scoped `delete_all/1` below) -- these are async,
  ##       best-effort mutations over existing data, not metadata changes;
  ##       there's no automatic inverse.
  ##
  ## `execute_ddl/1` raises a specific, actionable `ArgumentError` if handed
  ## an `{:alter, %Table{}, subcommands}` tuple that includes a `:modify`
  ## subcommand, calling out that it's in the "unsafe" category above and
  ## must be written as explicit `up/0`/`down/0` (or raw `execute/1` SQL),
  ## rather than falling through to the generic "not implemented" message.
  ##
  ## ## `ORDER BY` / partition key changes after `CREATE TABLE`
  ##
  ## `ALTER TABLE ... MODIFY ORDER BY new_expr` has no representation in
  ## `Ecto.Migration`'s DSL at all (there is no `alter table(...) do modify
  ## order_by(...) end` -- Ecto's `:alter` subcommands only cover columns).
  ## The only way to issue it is a raw SQL string passed to `execute/1`, and
  ## `execute_ddl/1` (this module) passes such strings through verbatim (see
  ## the `is_binary/1` clause below) -- so an explicit, intentional
  ## `MODIFY ORDER BY` is never blocked. What's guarded against is an
  ## *implicit* one: since it's structurally unreachable via `change/0`
  ## auto-reversal, a migration author changing a sort key must write it as
  ## explicit `up/0` + `down/0`, and the `down/0` cannot actually restore the
  ## prior physical layout -- at best it can issue another `MODIFY ORDER BY`
  ## back to the old expression, which reorders future merges but does not
  ## undo merges that already happened under the new key. Document that
  ## caveat in the migration itself; there is nothing this adapter can
  ## auto-generate here.
  ##
  ## ## Data-skipping indices (`ALTER TABLE ... ADD INDEX ... TYPE ...`)
  ##
  ## `Ecto.Migration.index/3` (`create index(...)`) models a Postgres/MySQL
  ## B-tree-shaped index: a column list plus `unique:`/`using:`/`where:`.
  ## ClickHouse's data-skipping indices (`minmax`, `set`, `bloom_filter`,
  ## `ngrambf_v1`, `tokenbf_v1`, ...) are a different mechanism entirely --
  ## an arbitrary expression, a type with its own positional tuning
  ## parameters (e.g. `bloom_filter(0.01)`), and a `GRANULARITY n`, used to
  ## skip whole granules during a scan rather than to accelerate point
  ## lookups. None of `index/3`'s fields map onto that shape, and stuffing
  ## `type(params) GRANULARITY n` into `using:` would misrepresent `using:`'s
  ## documented meaning (an index method name like `:gin`/`:hash`) for every
  ## other adapter that reads it.
  ##
  ## This adapter does not introduce a ClickHouse-specific
  ## migration DSL command for these. `execute_ddl/1` only recognizes the
  ## handful of `Ecto.Migration.Command` shapes documented above; a
  ## `{:create, %Index{}}` (from `create index(...)`) falls through to the
  ## generic clause at the bottom of this section, which raises and points
  ## at `execute/1`. Add and drop data-skipping indices with raw SQL:
  ##
  ##     execute("ALTER TABLE events ADD INDEX amount_minmax_idx amount TYPE minmax GRANULARITY 4")
  ##     execute("ALTER TABLE events DROP INDEX amount_minmax_idx")
  ##
  ## Adding an index is metadata-only and applies to parts written from then
  ## on; existing parts are only covered once `ALTER TABLE ... MATERIALIZE
  ## INDEX name` (or the next merge) rebuilds them -- run `MATERIALIZE INDEX`
  ## explicitly in the same migration if the index needs to cover existing
  ## data immediately. `change/0` cannot auto-reverse either statement (it
  ## doesn't know either shape), so write these as explicit `up/0` + `down/0`
  ## using `execute/1` for both directions.
  ##
  ## ## Projections (`ALTER TABLE ... ADD PROJECTION`)
  ##
  ## Out of scope for this adapter's migration support. A projection defines
  ## an alternate physical layout (its own sort order and/or aggregation) of
  ## the same table data, materialized and kept in sync by ClickHouse in the
  ## background -- closer to a materialized view bolted onto the table than
  ## to an index. It doesn't share data-skipping indices' comparatively
  ## simple `ADD INDEX name expr TYPE type(params) GRANULARITY n` grammar
  ## (`ADD PROJECTION` takes an arbitrary `SELECT`-shaped body), and nothing
  ## about it is trivial enough to justify adapter-level support before a
  ## concrete use case demands it. Use raw SQL via `execute/1` if needed.
  ##
  ## ## Kafka-engine tables and materialized views (streaming ingestion)
  ##
  ## ClickHouse's standard Kafka ingestion pipeline is three separate
  ## pieces wired together, none of which fit `Ecto.Migration.Table`'s
  ## column-list DSL:
  ##
  ##   1. A target table (an ordinary MergeTree-family table) -- already
  ##      fully supported by `create table(...)` above.
  ##   2. A `Kafka`-engine source table (`CREATE TABLE ... ENGINE = Kafka
  ##      SETTINGS kafka_broker_list = ..., kafka_topic_list = ...,
  ##      kafka_group_name = ..., kafka_format = ...`), whose "columns" are
  ##      the parsed message fields plus virtual columns (`_topic`,
  ##      `_partition`, `_offset`, `_timestamp`, `_headers.name`/
  ##      `_headers.value`) that ClickHouse injects and that no
  ##      `Ecto.Migration.Table` column list could express anyway.
  ##   3. A materialized view (`CREATE MATERIALIZED VIEW mv_name TO
  ##      target_table AS SELECT ... FROM kafka_table`) -- semantically a
  ##      standing INSERT trigger that fires once per Kafka poll batch, not
  ##      an on-demand-refreshed view.
  ##
  ## This adapter does not add a dedicated migration DSL for any of the
  ## three. `execute_ddl/1`'s `is_binary/1` clause already passes raw SQL
  ## strings through verbatim, which is the same mechanism this module
  ## already relies on for `MODIFY ORDER BY`, data-skipping indices, and
  ## projections above -- Kafka table DDL and a view's `AS SELECT ...`
  ## body are no less arbitrary than those, so introducing adapter-level
  ## sugar here would just be a second, narrower way to spell `execute/1`
  ## with none of its generality. Write all three pieces as raw SQL in a
  ## migration's `up/0`:
  ##
  ##     execute("""
  ##     CREATE TABLE events (id UInt64, payload String)
  ##     ENGINE = MergeTree ORDER BY id
  ##     """)
  ##
  ##     execute("""
  ##     CREATE TABLE events_queue (id UInt64, payload String)
  ##     ENGINE = Kafka
  ##     SETTINGS kafka_broker_list = 'kafka:9092',
  ##              kafka_topic_list = 'events',
  ##              kafka_group_name = 'events_consumer',
  ##              kafka_format = 'JSONEachRow'
  ##     """)
  ##
  ##     execute("""
  ##     CREATE MATERIALIZED VIEW events_mv TO events AS
  ##     SELECT id, payload FROM events_queue
  ##     """)
  ##
  ## Only the explicit `CREATE MATERIALIZED VIEW ... TO target_table AS
  ## SELECT ...` form is supported/documented; the implicit-target-table
  ## form (`CREATE MATERIALIZED VIEW ... ENGINE = ... AS SELECT ...`,
  ## where ClickHouse creates and owns a hidden backing table) is out of
  ## scope. The hidden table has no name a migration's `down/0` can address
  ## directly (ClickHouse mangles it, e.g. `.inner.<uuid>`), which turns a
  ## clean, explicit teardown into guesswork; requiring `TO target_table`
  ## keeps every piece a migration creates addressable by the name that
  ## migration chose.
  ##
  ## None of this is safely auto-reversible, so write `up/0` + `down/0`
  ## explicitly -- never `change/0`. The three pieces must be created and
  ## torn down in specific orders:
  ##
  ##   Creation order (`up/0`): target table, then the Kafka source table,
  ##   then the materialized view. Only the Kafka table is a hard
  ##   requirement before the view -- `CREATE MATERIALIZED VIEW ... AS
  ##   SELECT ... FROM kafka_table` resolves and validates the `FROM`
  ##   table's columns immediately (`CREATE TABLE ... AS SELECT FROM
  ##   <nonexistent>` fails with `UNKNOWN_TABLE`), while the `TO
  ##   target_table` name is not validated until the first insert.
  ##   Creating the target table first anyway keeps a consistent,
  ##   unsurprising order and means the view is never live before
  ##   somewhere to write actually exists.
  ##
  ##   Teardown order (`down/0`): materialized view, then the Kafka source
  ##   table, then the target table -- the reverse of creation, and not
  ##   interchangeable. `DROP TABLE` on the Kafka source table stops its
  ##   background consumer immediately and cleanly (the row in
  ##   `system.kafka_consumers` disappears, no entry lingers in
  ##   `kafka-consumer-groups.sh --list`) regardless of
  ##   what else references it, so it never orphans a consumer group by
  ##   itself. The actual hazard is dropping the *target* table while the
  ##   materialized view and Kafka table are still live: ClickHouse allows
  ##   the `DROP TABLE` on the target with no error and no dependency
  ##   check, but the view is left silently pointing at nothing --
  ##   ingestion stalls with no exception surfaced anywhere (not in
  ##   `system.kafka_consumers.exceptions.text`, not in the server log).
  ##   Dropping the view first removes the trigger before either table
  ##   underneath it goes away, so there is no window where a poll batch
  ##   can fire into a broken pipeline.
  ##
  ## ## `FixedString(N)`, `LowCardinality(T)`, and `Map(K, V)` in migrations
  ##
  ## All three are ClickHouse-specific column types with no built-in Ecto
  ## migration type, so all three ultimately reach `column_type!/1` as the
  ## quoted-atom escape hatch below (`add(:col, :"FixedString(16)")`) --
  ## `Ecto.Migration.add/3` validates its own `type` argument before this
  ## module ever sees it, and that validation unconditionally rejects any
  ## `Ecto.Type`/`Ecto.ParameterizedType` module (passing
  ## one directly raises "Types defined through Ecto.Type or
  ## Ecto.ParameterizedType aren't allowed, use their underlying types
  ## instead"), so no amount of adapter-side wiring can make a real
  ## parameterized-type module itself acceptable as a migration `add/3`
  ## type -- the quoted atom is the only spelling Ecto leaves available.
  ##
  ## `Ecto.Adapters.ClickHouse.Migration.fixed_string/1` and `.low_cardinality/1`
  ## build that quoted atom for you, with the parameter validated up front
  ## instead of only surfacing as a ClickHouse DDL error at migration time:
  ##
  ##     add(:code, Ecto.Adapters.ClickHouse.Migration.fixed_string(16))
  ##     add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))
  ##
  ## `FixedString(N)` additionally gets a full `Ecto.ParameterizedType` --
  ## `Ecto.Adapters.ClickHouse.Types.FixedString` -- for the schema side,
  ## where `add/3`'s restriction above doesn't apply:
  ##
  ##     field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16
  ##
  ## `LowCardinality(T)` does not get one, by design: it's transparent to
  ## callers (`ChDriver.Protocol.NativeBlock` decodes it to the exact same
  ## Elixir value `T` would decode to on its own), so a plain `field
  ## :status, :string` (or whatever `T` maps to) already behaves correctly
  ## with no dedicated type -- `low_cardinality/1` exists purely to
  ## validate and build the migration-side type string. `Map(K, V)` gets
  ## neither: it has two independent type parameters (and ClickHouse
  ## further restricts which types `K` may be), and no builder here
  ## enforces that -- see `Ecto.Adapters.ClickHouse.Migration`'s moduledoc
  ## for the full reasoning. Use the raw quoted atom directly for `Map`:
  ##
  ##     add(:m, :"Map(String, UInt32)")
  ##
  ## Every table this generates DDL for needs an `ENGINE`. If the migration
  ## author passes `options: "ENGINE = ... "` (via `table(:foo, options:
  ## "ENGINE = MergeTree ORDER BY id")`) that raw string is used verbatim;
  ## otherwise this defaults to `ENGINE = MergeTree ORDER BY (<primary key
  ## columns>)` (or `ORDER BY tuple()` if there are none) -- good enough for
  ## `schema_migrations` (which Ecto marks `version` as `primary_key: true`)
  ## and for quick dev tables, but MergeTree's ordering/partitioning key is a
  ## real modeling decision for anything performance-sensitive -- pass
  ## `options:` explicitly once that matters.
  @impl true
  def execute_ddl(string) when is_binary(string), do: [string]

  def execute_ddl({command, %Table{} = table, commands})
      when command in [:create, :create_if_not_exists] do
    engine = engine_clause(table, commands)

    [
      IO.iodata_to_binary([
        "CREATE TABLE ",
        if(command == :create_if_not_exists, do: "IF NOT EXISTS ", else: ""),
        quote_table(table.prefix, table.name),
        " (",
        Enum.map_intersperse(commands, ", ", &column_definition!/1),
        ") ",
        engine
      ])
    ]
  end

  def execute_ddl({command, %Table{} = table, _mode})
      when command in [:drop, :drop_if_exists] do
    [
      IO.iodata_to_binary([
        "DROP TABLE ",
        if(command == :drop_if_exists, do: "IF EXISTS ", else: ""),
        quote_table(table.prefix, table.name)
      ])
    ]
  end

  def execute_ddl({:alter, %Table{} = table, subcommands}) do
    if Enum.any?(subcommands, &match?({:modify, _, _, _}, &1)) do
      raise ArgumentError,
            "refusing to auto-generate DDL for a :modify column on table " <>
              "#{inspect(table.name)}: changing an existing column's type in ClickHouse " <>
              "(`ALTER TABLE ... MODIFY COLUMN`) triggers an asynchronous mutation that " <>
              "rewrites every existing part and can irreversibly coerce/truncate data -- this " <>
              "is NOT safe to auto-reverse via change/0. Write this as an explicit up/0 + " <>
              "down/0 migration using raw execute/1 SQL, and make sure the down/0 direction " <>
              "reflects that the original values may not be perfectly recoverable."
    else
      raise ArgumentError,
            "the ClickHouse adapter does not implement :alter (add/remove column) DDL yet for " <>
              "table #{inspect(table.name)}, even though ADD COLUMN/DROP COLUMN are " <>
              "conceptually safe to auto-reverse (synchronous, metadata-only) -- see this " <>
              "module's `## DDL` section. Use raw SQL via execute/1 for both the forward and " <>
              "reverse direction in the meantime: #{inspect(subcommands)}"
    end
  end

  def execute_ddl(command) do
    raise ArgumentError,
          "the ClickHouse adapter's Ecto.Migration DDL support only covers a plain " <>
            "CREATE TABLE/DROP TABLE with :add column commands (see this module's `## DDL` " <>
            "section) -- got: #{inspect(command)}. Use a raw SQL string in your migration's " <>
            "`execute/1`, or run DDL directly via ChDriver.query/2 outside of Ecto.Migration " <>
            "for anything else (ALTER TABLE, indexes, constraints, ...)."
  end

  defp engine_clause(%Table{options: options}, _commands) when is_binary(options), do: options

  defp engine_clause(%Table{options: nil}, commands) do
    primary_key_columns =
      for {:add, name, _type, opts} <- commands, Keyword.get(opts, :primary_key, false) do
        quote_name(name)
      end

    order_by =
      if primary_key_columns == [],
        do: "tuple()",
        else: [?(, Enum.intersperse(primary_key_columns, ?,), ?)]

    ["ENGINE = MergeTree ORDER BY " | order_by]
  end

  defp column_definition!({:add, name, %Reference{}, _opts}) do
    raise ArgumentError,
          "the ClickHouse adapter does not support column references/foreign keys in " <>
            "migrations (ClickHouse has no foreign-key constraints) -- got column " <>
            "#{inspect(name)}. Store the referenced id as a plain integer column instead."
  end

  defp column_definition!({:add, name, type, opts}) do
    base_type = column_type!(type)

    # `null: true` is Ecto's own default (matching every other Ecto
    # adapter): a column is nullable unless `null: false` is given
    # explicitly. `ChDriver.Protocol.NativeBlock` now decodes `Nullable(T)`
    # (clickhouse_adapter_elixir-8a2.17), so this maps straight through to a
    # `Nullable(...)` column type. A `:primary_key` column is never
    # wrapped in `Nullable`, regardless of the `:null` option, since
    # ClickHouse's `ORDER BY`/primary key columns can't be `Nullable`.
    nullable? =
      Keyword.get(opts, :null, true) == true and not Keyword.get(opts, :primary_key, false)

    type_sql = if nullable?, do: ["Nullable(", base_type, ?)], else: base_type

    [quote_name(name), " ", type_sql]
  end

  defp column_definition!(other) do
    raise ArgumentError,
          "the ClickHouse adapter's migration DDL only supports :add column commands in " <>
            "CREATE TABLE -- got: #{inspect(other)} (no :alter/:modify/:remove support)"
  end

  # Exposed (rather than kept `defp`) so
  # `Ecto.Adapters.ClickHouse.Migration.low_cardinality/1` can resolve an
  # inner Ecto type to its ClickHouse column-type string through the same
  # single mapping this module's own DDL generation uses, instead of
  # duplicating it.
  @doc false
  def column_type!(:id), do: "UInt64"
  def column_type!(:serial), do: "UInt64"
  def column_type!(:bigserial), do: "UInt64"
  def column_type!(:integer), do: "Int32"
  def column_type!(:bigint), do: "Int64"
  def column_type!(:smallint), do: "Int16"
  def column_type!(:float), do: "Float64"
  def column_type!(:boolean), do: "UInt8"
  def column_type!(:string), do: "String"
  def column_type!(:text), do: "String"
  def column_type!(:binary), do: "String"
  def column_type!(:uuid), do: "UUID"
  def column_type!(:naive_datetime), do: "DateTime"
  def column_type!(:naive_datetime_usec), do: "DateTime64(6)"
  def column_type!(:utc_datetime), do: "DateTime"
  def column_type!(:utc_datetime_usec), do: "DateTime64(6)"
  def column_type!(:date), do: "Date"
  def column_type!(:decimal), do: "Decimal(38, 9)"

  # `IPv4`/`IPv6` (clickhouse_adapter_elixir-8a2.21) decode to their dotted-
  # quad/colon-hex text forms (see
  # `ChDriver.Protocol.NativeBlock.decode_ipv4/1`/`decode_ipv6/1`) and accept
  # a plain string literal on INSERT (ClickHouse parses `'192.168.1.1'`/
  # `'2001:db8::1'` into the column's native binary representation itself,
  # confirmed live) -- so, like `:uuid`, they're plain first-class Ecto
  # migration types here with a plain `:string` schema field on the other
  # end.
  def column_type!(:ipv4), do: "IPv4"
  def column_type!(:ipv6), do: "IPv6"

  # `{:array, inner_type}` is Ecto's own built-in shorthand for an array
  # column (`add(:tags, {:array, :string})` in a migration) -- maps
  # straight onto ClickHouse's `Array(T)` (clickhouse_adapter_elixir-8a2.19),
  # recursing so `{:array, :integer}` -> `Array(Int32)`, etc.
  def column_type!({:array, inner_type}), do: "Array(#{column_type!(inner_type)})"

  # A raw ClickHouse type given verbatim as a *quoted atom* (e.g.
  # `add(:status, :"LowCardinality(String)")`) -- `Ecto.Migration.add/3`
  # validates its `type` argument itself before this adapter ever sees it,
  # and only accepts atoms/quoted-atoms/composite tuples/references (a
  # plain string is rejected outright with "invalid migration type",
  # confirmed live), so a quoted atom -- exactly what Ecto's own error
  # message suggests for adapter-specific types -- is the escape hatch here
  # rather than a raw binary. This is for ClickHouse-specific column types
  # with no clean Ecto-type equivalent (`LowCardinality(T)` chief among
  # them: it's transparent to callers -- `ChDriver.Protocol.NativeBlock`
  # decodes it to the same Elixir value `T` would decode to on its own --
  # so there's no dedicated Ecto migration type for it, just this
  # passthrough plus a plain `field :status, :string` (or whatever `T`
  # maps to) on the schema side). Guarded on containing `(` so a genuine
  # typo'd Ecto type atom (e.g. `:sting`) still raises the helpful error
  # below instead of silently becoming bogus DDL.
  def column_type!(other) when is_atom(other) do
    raw = Atom.to_string(other)

    if String.contains?(raw, "(") do
      raw
    else
      raise_unknown_column_type!(other)
    end
  end

  def column_type!(other), do: raise_unknown_column_type!(other)

  defp raise_unknown_column_type!(other) do
    raise ArgumentError,
          "the ClickHouse adapter's migration DDL does not know how to map the Ecto type " <>
            "#{inspect(other)} to a ClickHouse column type -- use a raw SQL string via " <>
            "`execute/1` in your migration for this column instead"
  end

  @impl true
  def ddl_logs(_result), do: []

  @impl true
  def table_exists_query(table) do
    {"SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = ? LIMIT 1",
     [table]}
  end

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
    [?', escape_string(literal), ?']
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

  ## Quoting -- confirmed live against ClickHouse 24.8: double quotes are
  ## accepted for identifiers (`SELECT "id" FROM "events"`); backticks work
  ## too, but double quotes are the ANSI-standard choice and match what the
  ## rest of the Ecto ecosystem (Postgres) expects, so that's what's used
  ## here. Single quotes remain reserved for string literals.

  defp quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  defp quote_name(name) when is_binary(name) do
    if String.contains?(name, "\"") do
      error!(nil, "bad literal/field/table name #{inspect(name)} (\" is not permitted)")
    end

    [?", name, ?"]
  end

  defp quote_names(names), do: Enum.map_intersperse(names, ?,, &quote_name/1)

  defp quote_table(nil, name), do: quote_table(name)
  defp quote_table(prefix, name), do: [quote_table(prefix), ?., quote_table(name)]

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

defimpl String.Chars, for: ChDriver.Query do
  @moduledoc false
  # `Ecto.Adapters.SQL.log/5` calls `to_string/1` on the cached query when
  # emitting `[:ecto_adapter, :query]` telemetry log entries; without this
  # `ChDriver.Query` has no `String.Chars` implementation and every
  # successful query raises (harmlessly, but noisily -- the query itself
  # already succeeded by the time logging runs) a `Protocol.UndefinedError`
  # from inside the logging callback.
  def to_string(%ChDriver.Query{statement: statement}), do: statement
end
