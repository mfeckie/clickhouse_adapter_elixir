defmodule Ecto.Adapters.ClickHouse.DDL do
  @moduledoc """
  DDL generation for `Ecto.Migration` support.

  Only `CREATE TABLE [IF NOT EXISTS]` (from `Ecto.Migration.Table` plus a
  column list of plain `{:add, name, type, opts}` commands) and
  `DROP TABLE [IF EXISTS]` are implemented. That's enough for
  `Ecto.Migrator` to create and manage the `schema_migrations` table, and
  for a migration's own `create table(...)`/`drop table(...)` to work for
  simple, single-statement tables.

  `:alter` (adding/removing/modifying columns on an existing table),
  indexes, and constraints are not implemented -- ClickHouse has no
  unique/foreign-key constraints at all, and its `ALTER TABLE` semantics
  don't map cleanly onto `Ecto.Migration.Table`'s `:alter` subcommands.
  Use a raw SQL string via `execute/1` for anything beyond a one-shot
  `CREATE`/`DROP TABLE`.

  ## `change/0` auto-reversal

  Ecto synthesizes a migration's `down` direction from `change/0`. That's
  only safe for synchronous, metadata-only operations:

    * `create table(...)` / `drop table(...)` -- implemented, safe.
    * `add :col, :type` / `remove :col` -- conceptually safe (ClickHouse's
      `ADD COLUMN`/`DROP COLUMN` are synchronous metadata changes), but
      not yet implemented here (`:alter` is rejected below). Use raw
      `execute/1` SQL for both directions until it lands.

  Write explicit `up/0` + `down/0` instead of `change/0` for anything that
  triggers an asynchronous mutation or rewrites existing data -- there is
  no safe way to auto-generate the reverse for:

    * `ALTER TABLE ... MODIFY ORDER BY` / partition key changes.
    * `ALTER TABLE ... MODIFY COLUMN <type>` (a real type change).
    * Any `UPDATE`/`DELETE`-shaped mutation on existing rows.

  `execute_ddl/1` raises with an explanation if you try to `:modify` a
  column's type, rather than falling through to a generic "not
  implemented" error.

  ## Things with no migration DSL -- use raw SQL

  A few ClickHouse features have no `Ecto.Migration` equivalent, so this
  adapter doesn't invent one for them. Use `execute/1` directly, as
  explicit `up/0` + `down/0` (none of this is auto-reversible):

    * **`ORDER BY`/partition key changes** --
      `ALTER TABLE ... MODIFY ORDER BY new_expr`. Note that `down/0` can't
      actually restore the old physical layout; at best it can issue
      another `MODIFY ORDER BY` back to the old expression, which affects
      future merges but not ones that already happened under the new key.

    * **Data-skipping indices** (`minmax`, `set`, `bloom_filter`,
      `ngrambf_v1`, `tokenbf_v1`, ...):

          execute("ALTER TABLE events ADD INDEX amount_minmax_idx amount TYPE minmax GRANULARITY 4")
          execute("ALTER TABLE events DROP INDEX amount_minmax_idx")

      Adding an index is metadata-only and only covers parts written
      afterward. Run `ALTER TABLE ... MATERIALIZE INDEX name` in the same
      migration if it needs to cover existing data immediately.

    * **Projections** (`ALTER TABLE ... ADD PROJECTION`) -- out of scope
      entirely; not supported through any mechanism here besides raw SQL.

    * **Kafka-engine ingestion pipelines** (source table + target table +
      materialized view):

          execute(\"\"\"
          CREATE TABLE events (id UInt64, payload String)
          ENGINE = MergeTree ORDER BY id
          \"\"\")

          execute(\"\"\"
          CREATE TABLE events_queue (id UInt64, payload String)
          ENGINE = Kafka
          SETTINGS kafka_broker_list = 'kafka:9092',
                   kafka_topic_list = 'events',
                   kafka_group_name = 'events_consumer',
                   kafka_format = 'JSONEachRow'
          \"\"\")

          execute(\"\"\"
          CREATE MATERIALIZED VIEW events_mv TO events AS
          SELECT id, payload FROM events_queue
          \"\"\")

      Only the explicit `... TO target_table AS SELECT ...` view form is
      supported; the implicit-target-table form
      (`ENGINE = ... AS SELECT ...`) creates a hidden backing table with a
      mangled name `down/0` can't address, so avoid it here. Create in
      this order: target table, Kafka source table, materialized view.
      Tear down in reverse: view, then Kafka table, then target table --
      dropping the target table while the view is still live leaves
      ingestion silently stalled with no error surfaced anywhere.

  ## ClickHouse-specific column types

  `FixedString(N)` and `LowCardinality(T)` have no built-in Ecto migration
  type, so a raw column type reaches `column_type!/1` via the quoted-atom
  escape hatch (`add(:col, :"FixedString(16)")`) -- `Ecto.Migration.add/3`
  rejects a real `Ecto.Type`/`Ecto.ParameterizedType` module outright, so
  the quoted atom is the only spelling available.
  `Ecto.Adapters.ClickHouse.Migration` provides validated builders instead
  of hand-typing that string:

      add(:code, Ecto.Adapters.ClickHouse.Migration.fixed_string(16))
      add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))

  `FixedString(N)` also has a schema-side `Ecto.ParameterizedType`:

      field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16

  `Map(K, V)` has no builder -- use the quoted atom directly:

      add(:m, :"Map(String, UInt32)")

  Every table needs an `ENGINE`. Pass one explicitly via `options:` on
  `table/2` (e.g. `options: "ENGINE = MergeTree ORDER BY id"`); without
  it, this defaults to `ENGINE = MergeTree ORDER BY (<primary key
  columns>)` (or `ORDER BY tuple()` with none). That default is fine for
  `schema_migrations` and quick dev tables, but MergeTree's sort key is a
  real modeling decision for anything performance-sensitive -- pick it
  explicitly once that matters.

  ## `ORDER BY`/`PRIMARY KEY` is not a Postgres primary key

  See `Ecto.Adapters.ClickHouse`'s moduledoc for the short version. In
  short: ClickHouse never enforces uniqueness on `ORDER BY`/`PRIMARY KEY`,
  and there's no autoincrement, so relying on Ecto's default autogenerated
  `:id` silently writes `0` for every row instead of raising. Use
  `primary_key: false` with an explicit, application-supplied id, and
  remember ClickHouse won't reject a duplicate on its own -- deduplication
  has to be handled at the application level or via a ClickHouse-native
  mechanism like `ReplacingMergeTree` if you need it.
  """

  alias Ecto.Adapters.ClickHouse.Naming
  alias Ecto.Migration.{Reference, Table}

  @doc false
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
              "module's moduledoc. Use raw SQL via execute/1 for both the forward and " <>
              "reverse direction in the meantime: #{inspect(subcommands)}"
    end
  end

  def execute_ddl(command) do
    raise ArgumentError,
          "the ClickHouse adapter's Ecto.Migration DDL support only covers a plain " <>
            "CREATE TABLE/DROP TABLE with :add column commands (see this module's " <>
            "moduledoc) -- got: #{inspect(command)}. Use a raw SQL string in your migration's " <>
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
    # explicitly. `ChDriver.Protocol.NativeBlock` decodes `Nullable(T)`,
    # so this maps straight through to a
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

  # `IPv4`/`IPv6` decode to their dotted-
  # quad/colon-hex text forms (see
  # `ChDriver.Protocol.NativeBlock.decode_ipv4/1`/`decode_ipv6/1`) and accept
  # a plain string literal on INSERT (ClickHouse parses `'192.168.1.1'`/
  # `'2001:db8::1'` into the column's native binary representation itself)
  # -- so, like `:uuid`, they're plain first-class Ecto
  # migration types here with a plain `:string` schema field on the other
  # end.
  def column_type!(:ipv4), do: "IPv4"
  def column_type!(:ipv6), do: "IPv6"

  # `{:array, inner_type}` is Ecto's own built-in shorthand for an array
  # column (`add(:tags, {:array, :string})` in a migration) -- maps
  # straight onto ClickHouse's `Array(T)`,
  # recursing so `{:array, :integer}` -> `Array(Int32)`, etc.
  def column_type!({:array, inner_type}), do: "Array(#{column_type!(inner_type)})"

  # A raw ClickHouse type given verbatim as a *quoted atom* (e.g.
  # `add(:status, :"LowCardinality(String)")`) -- `Ecto.Migration.add/3`
  # validates its `type` argument itself before this adapter ever sees it,
  # and only accepts atoms/quoted-atoms/composite tuples/references (a
  # plain string is rejected outright with "invalid migration type"),
  # so a quoted atom -- exactly what Ecto's own error
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

  @doc false
  def ddl_logs(_result), do: []

  @doc false
  def table_exists_query(table) do
    {"SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = ? LIMIT 1",
     [table]}
  end

  # `quote_name/1` and `quote_table/1,2` are shared with the SELECT/expression
  # builder (identifier quoting is the same regardless of whether the
  # identifier appears in DDL or a query), so they stay defined in
  # `Ecto.Adapters.ClickHouse.Naming` as the single source of truth and are
  # called through as `Naming.quote_name/1` / `Naming.quote_table/1,2` here
  # rather than duplicated.
  defp quote_name(name), do: Naming.quote_name(name)
  defp quote_table(prefix, name), do: Naming.quote_table(prefix, name)
end
