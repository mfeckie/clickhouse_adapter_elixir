defmodule Ecto.Adapters.ClickHouse.DDL do
  @moduledoc """
  DDL generation for `Ecto.Migration` support.

  Only `CREATE TABLE [IF NOT EXISTS]` (from `Ecto.Migration.Table` + a
  column list of plain `{:add, name, type, opts}` commands) and
  `DROP TABLE [IF EXISTS]` are implemented -- enough to let
  `Ecto.Migration.SchemaMigration.ensure_schema_migrations_table!/3`
  (called internally by `Ecto.Migrator`) create the `schema_migrations`
  table, and for a migration author's own `create table(...)` /
  `drop table(...)` to work for simple, single-statement tables.

  `:alter` (adding/removing/modifying columns on an existing table),
  indexes, and constraints are NOT implemented -- ClickHouse's ALTER TABLE
  semantics (async mutations, `ADD COLUMN`/`MODIFY COLUMN` quirks per
  engine) don't map cleanly onto `Ecto.Migration.Table`'s `:alter`
  subcommands, and ClickHouse has no unique/foreign-key constraints at
  all. Use a raw SQL string via `execute/1` in a migration for anything
  beyond a one-shot `CREATE`/`DROP TABLE`.

  ## Which DDL is safe for `change/0` auto-reversal, and which isn't

  Ecto's `change/0` migrations rely on `Ecto.Migration`'s built-in
  reversal (`create table(...)` -> `drop table(...)`, `add :col, :type` ->
  `remove :col`, etc) to synthesize the `down` direction for you. Whether
  that's *safe* to auto-generate for ClickHouse specifically depends on
  whether the underlying operation is synchronous/metadata-only or an
  asynchronous, potentially-lossy rewrite:

    SAFE for `change/0` (synchronous, metadata-only, reverses cleanly):
      * `create table(...)` / `drop table(...)` -- implemented here.
      * `add :col, :type` / `remove :col` -- ClickHouse's
        `ALTER TABLE ... ADD COLUMN` / `DROP COLUMN` are synchronous
        metadata changes (no data rewrite), same category as `CREATE`/
        `DROP TABLE`. **Not yet implemented in this adapter** (`:alter` is
        rejected below) -- conceptually safe to auto-reverse, just not
        built yet; use raw `execute/1` SQL for both directions until it is.

    UNSAFE -- require explicit `up/0` + `down/0`, never `change/0`:
      * `ALTER TABLE ... MODIFY ORDER BY` / partition key changes --
        MergeTree's ORDER BY/PARTITION BY defines the on-disk sort order
        and physically reorganizes existing parts; there is no generic
        "undo" (the old physical layout isn't recoverable from the new
        one), and Ecto has no built-in reversal for this operation anyway.
      * `ALTER TABLE ... MODIFY COLUMN <type>` (a real type change, not a
        widening no-op) -- this triggers an asynchronous background
        mutation that rewrites every existing part; data can be
        irreversibly truncated/coerced during the rewrite (e.g. String ->
        Int32 on non-numeric values), so "reversing" it by mutating back
        to the old type does not restore the original bytes.
      * Any `UPDATE`/`DELETE`-shaped mutation on existing rows
        (`ALTER TABLE ... UPDATE/DELETE`, see `update_all/2` and the
        narrowly-scoped `delete_all/1` below) -- these are async,
        best-effort mutations over existing data, not metadata changes;
        there's no automatic inverse.

  `execute_ddl/1` raises a specific, actionable `ArgumentError` if handed
  an `{:alter, %Table{}, subcommands}` tuple that includes a `:modify`
  subcommand, calling out that it's in the "unsafe" category above and
  must be written as explicit `up/0`/`down/0` (or raw `execute/1` SQL),
  rather than falling through to the generic "not implemented" message.

  ## `ORDER BY` / partition key changes after `CREATE TABLE`

  `ALTER TABLE ... MODIFY ORDER BY new_expr` has no representation in
  `Ecto.Migration`'s DSL at all (there is no `alter table(...) do modify
  order_by(...) end` -- Ecto's `:alter` subcommands only cover columns).
  The only way to issue it is a raw SQL string passed to `execute/1`, and
  `execute_ddl/1` (this module) passes such strings through verbatim (see
  the `is_binary/1` clause below) -- so an explicit, intentional
  `MODIFY ORDER BY` is never blocked. What's guarded against is an
  *implicit* one: since it's structurally unreachable via `change/0`
  auto-reversal, a migration author changing a sort key must write it as
  explicit `up/0` + `down/0`, and the `down/0` cannot actually restore the
  prior physical layout -- at best it can issue another `MODIFY ORDER BY`
  back to the old expression, which reorders future merges but does not
  undo merges that already happened under the new key. Document that
  caveat in the migration itself; there is nothing this adapter can
  auto-generate here.

  ## Data-skipping indices (`ALTER TABLE ... ADD INDEX ... TYPE ...`)

  `Ecto.Migration.index/3` (`create index(...)`) models a Postgres/MySQL
  B-tree-shaped index: a column list plus `unique:`/`using:`/`where:`.
  ClickHouse's data-skipping indices (`minmax`, `set`, `bloom_filter`,
  `ngrambf_v1`, `tokenbf_v1`, ...) are a different mechanism entirely --
  an arbitrary expression, a type with its own positional tuning
  parameters (e.g. `bloom_filter(0.01)`), and a `GRANULARITY n`, used to
  skip whole granules during a scan rather than to accelerate point
  lookups. None of `index/3`'s fields map onto that shape, and stuffing
  `type(params) GRANULARITY n` into `using:` would misrepresent `using:`'s
  documented meaning (an index method name like `:gin`/`:hash`) for every
  other adapter that reads it.

  This adapter does not introduce a ClickHouse-specific
  migration DSL command for these. `execute_ddl/1` only recognizes the
  handful of `Ecto.Migration.Command` shapes documented above; a
  `{:create, %Index{}}` (from `create index(...)`) falls through to the
  generic clause at the bottom of this section, which raises and points
  at `execute/1`. Add and drop data-skipping indices with raw SQL:

      execute("ALTER TABLE events ADD INDEX amount_minmax_idx amount TYPE minmax GRANULARITY 4")
      execute("ALTER TABLE events DROP INDEX amount_minmax_idx")

  Adding an index is metadata-only and applies to parts written from then
  on; existing parts are only covered once `ALTER TABLE ... MATERIALIZE
  INDEX name` (or the next merge) rebuilds them -- run `MATERIALIZE INDEX`
  explicitly in the same migration if the index needs to cover existing
  data immediately. `change/0` cannot auto-reverse either statement (it
  doesn't know either shape), so write these as explicit `up/0` + `down/0`
  using `execute/1` for both directions.

  ## Projections (`ALTER TABLE ... ADD PROJECTION`)

  Out of scope for this adapter's migration support. A projection defines
  an alternate physical layout (its own sort order and/or aggregation) of
  the same table data, materialized and kept in sync by ClickHouse in the
  background -- closer to a materialized view bolted onto the table than
  to an index. It doesn't share data-skipping indices' comparatively
  simple `ADD INDEX name expr TYPE type(params) GRANULARITY n` grammar
  (`ADD PROJECTION` takes an arbitrary `SELECT`-shaped body), and nothing
  about it is trivial enough to justify adapter-level support before a
  concrete use case demands it. Use raw SQL via `execute/1` if needed.

  ## Kafka-engine tables and materialized views (streaming ingestion)

  ClickHouse's standard Kafka ingestion pipeline is three separate
  pieces wired together, none of which fit `Ecto.Migration.Table`'s
  column-list DSL:

    1. A target table (an ordinary MergeTree-family table) -- already
       fully supported by `create table(...)` above.
    2. A `Kafka`-engine source table (`CREATE TABLE ... ENGINE = Kafka
       SETTINGS kafka_broker_list = ..., kafka_topic_list = ...,
       kafka_group_name = ..., kafka_format = ...`), whose "columns" are
       the parsed message fields plus virtual columns (`_topic`,
       `_partition`, `_offset`, `_timestamp`, `_headers.name`/
       `_headers.value`) that ClickHouse injects and that no
       `Ecto.Migration.Table` column list could express anyway.
    3. A materialized view (`CREATE MATERIALIZED VIEW mv_name TO
       target_table AS SELECT ... FROM kafka_table`) -- semantically a
       standing INSERT trigger that fires once per Kafka poll batch, not
       an on-demand-refreshed view.

  This adapter does not add a dedicated migration DSL for any of the
  three. `execute_ddl/1`'s `is_binary/1` clause already passes raw SQL
  strings through verbatim, which is the same mechanism this module
  already relies on for `MODIFY ORDER BY`, data-skipping indices, and
  projections above -- Kafka table DDL and a view's `AS SELECT ...`
  body are no less arbitrary than those, so introducing adapter-level
  sugar here would just be a second, narrower way to spell `execute/1`
  with none of its generality. Write all three pieces as raw SQL in a
  migration's `up/0`:

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

  Only the explicit `CREATE MATERIALIZED VIEW ... TO target_table AS
  SELECT ...` form is supported/documented; the implicit-target-table
  form (`CREATE MATERIALIZED VIEW ... ENGINE = ... AS SELECT ...`,
  where ClickHouse creates and owns a hidden backing table) is out of
  scope. The hidden table has no name a migration's `down/0` can address
  directly (ClickHouse mangles it, e.g. `.inner.<uuid>`), which turns a
  clean, explicit teardown into guesswork; requiring `TO target_table`
  keeps every piece a migration creates addressable by the name that
  migration chose.

  None of this is safely auto-reversible, so write `up/0` + `down/0`
  explicitly -- never `change/0`. The three pieces must be created and
  torn down in specific orders:

    Creation order (`up/0`): target table, then the Kafka source table,
    then the materialized view. Only the Kafka table is a hard
    requirement before the view -- `CREATE MATERIALIZED VIEW ... AS
    SELECT ... FROM kafka_table` resolves and validates the `FROM`
    table's columns immediately (`CREATE TABLE ... AS SELECT FROM
    <nonexistent>` fails with `UNKNOWN_TABLE`), while the `TO
    target_table` name is not validated until the first insert.
    Creating the target table first anyway keeps a consistent,
    unsurprising order and means the view is never live before
    somewhere to write actually exists.

    Teardown order (`down/0`): materialized view, then the Kafka source
    table, then the target table -- the reverse of creation, and not
    interchangeable. `DROP TABLE` on the Kafka source table stops its
    background consumer immediately and cleanly (the row in
    `system.kafka_consumers` disappears, no entry lingers in
    `kafka-consumer-groups.sh --list`) regardless of
    what else references it, so it never orphans a consumer group by
    itself. The actual hazard is dropping the *target* table while the
    materialized view and Kafka table are still live: ClickHouse allows
    the `DROP TABLE` on the target with no error and no dependency
    check, but the view is left silently pointing at nothing --
    ingestion stalls with no exception surfaced anywhere (not in
    `system.kafka_consumers.exceptions.text`, not in the server log).
    Dropping the view first removes the trigger before either table
    underneath it goes away, so there is no window where a poll batch
    can fire into a broken pipeline.

  ## `FixedString(N)`, `LowCardinality(T)`, and `Map(K, V)` in migrations

  All three are ClickHouse-specific column types with no built-in Ecto
  migration type, so all three ultimately reach `column_type!/1` as the
  quoted-atom escape hatch below (`add(:col, :"FixedString(16)")`) --
  `Ecto.Migration.add/3` validates its own `type` argument before this
  module ever sees it, and that validation unconditionally rejects any
  `Ecto.Type`/`Ecto.ParameterizedType` module (passing
  one directly raises "Types defined through Ecto.Type or
  Ecto.ParameterizedType aren't allowed, use their underlying types
  instead"), so no amount of adapter-side wiring can make a real
  parameterized-type module itself acceptable as a migration `add/3`
  type -- the quoted atom is the only spelling Ecto leaves available.

  `Ecto.Adapters.ClickHouse.Migration.fixed_string/1` and `.low_cardinality/1`
  build that quoted atom for you, with the parameter validated up front
  instead of only surfacing as a ClickHouse DDL error at migration time:

      add(:code, Ecto.Adapters.ClickHouse.Migration.fixed_string(16))
      add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))

  `FixedString(N)` additionally gets a full `Ecto.ParameterizedType` --
  `Ecto.Adapters.ClickHouse.Types.FixedString` -- for the schema side,
  where `add/3`'s restriction above doesn't apply:

      field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16

  `LowCardinality(T)` does not get one, by design: it's transparent to
  callers (`ChDriver.Protocol.NativeBlock` decodes it to the exact same
  Elixir value `T` would decode to on its own), so a plain `field
  :status, :string` (or whatever `T` maps to) already behaves correctly
  with no dedicated type -- `low_cardinality/1` exists purely to
  validate and build the migration-side type string. `Map(K, V)` gets
  neither: it has two independent type parameters (and ClickHouse
  further restricts which types `K` may be), and no builder here
  enforces that -- see `Ecto.Adapters.ClickHouse.Migration`'s moduledoc
  for the full reasoning. Use the raw quoted atom directly for `Map`:

      add(:m, :"Map(String, UInt32)")

  Every table this generates DDL for needs an `ENGINE`. If the migration
  author passes `options: "ENGINE = ... "` (via `table(:foo, options:
  "ENGINE = MergeTree ORDER BY id")`) that raw string is used verbatim;
  otherwise this defaults to `ENGINE = MergeTree ORDER BY (<primary key
  columns>)` (or `ORDER BY tuple()` if there are none) -- good enough for
  `schema_migrations` (which Ecto marks `version` as `primary_key: true`)
  and for quick dev tables, but MergeTree's ordering/partitioning key is a
  real modeling decision for anything performance-sensitive -- pass
  `options:` explicitly once that matters.

  ## `ORDER BY`/`PRIMARY KEY` is not a Postgres-style primary key -- read this before your first migration

  This is the single biggest footgun for anyone coming from Postgres or
  MySQL, so it's called out on its own here rather than only implied by
  the `ENGINE`-defaulting paragraph above. Confirmed empirically against a
  live ClickHouse server (see
  `test/integration/primary_key_semantics_test.exs`):

    * **`create table(:things) do add :name, :string end`, with no
      `primary_key: false`, does NOT raise or silently produce a broken
      column.** `Ecto.Migration` injects its own default `add :id,
      :bigserial, primary_key: true` column before this module ever sees
      the command list, exactly like it would for Postgres. This module's
      `engine_clause/2` already special-cases any `:add` column carrying
      `primary_key: true`: it becomes part of `ORDER BY`, `:bigserial`
      maps to `UInt64`, and the column is never wrapped in `Nullable(...)`
      (see `column_definition!/1`). The resulting `CREATE TABLE ... (id
      UInt64, name Nullable(String)) ENGINE = MergeTree ORDER BY (id)`
      is perfectly valid ClickHouse DDL and the migration succeeds.
    * **What actually breaks is what happens *after* `CREATE TABLE`, at
      insert time, and it's silent.** `ORDER BY`/`PRIMARY KEY` in
      ClickHouse is a sparse sorting/indexing key used to skip granules
      during a scan -- it is never enforced as unique at insert time,
      and ClickHouse has no server-side autoincrement for `id` to fall
      back on the way a Postgres `bigserial` sequence would. This adapter
      doesn't synthesize autogeneration either (no `:on_conflict`/
      `:returning` support -- see `Ecto.Adapters.ClickHouse.QueryBuilder`).
      So a schema using Ecto's default `@primary_key {:id, :id,
      autogenerate: true}` that omits `:id` from an insert -- the normal
      Postgres pattern of "let the database generate it" -- simply never
      sends a value for that column at all. ClickHouse fills it with the
      column type's default, `0` for `UInt64`, not a fresh unique value.
      Every row inserted this way lands on `id = 0`: **all of them are
      accepted with no error** (there is no uniqueness constraint to
      violate), but they become indistinguishable by "primary key" from
      one another.

  The correct, documented pattern is `primary_key: false` on `table/2`
  plus an explicit `id` column supplied by the application (a natural
  key, `Ecto.UUID.generate/0`, `System.unique_integer/1`, etc.) and an
  explicit `options:` `ORDER BY`/`ENGINE` once the default heuristic
  above isn't the right sort key for the table:

      create table(:events, primary_key: false, options: "ENGINE = MergeTree ORDER BY id") do
        add(:id, :uuid, primary_key: true)
        add(:name, :string)
        add(:occurred_at, :utc_datetime)
      end

  paired with a schema that supplies `:id` itself rather than trusting
  the adapter/database to autogenerate it:

      @primary_key false
      schema "events" do
        field(:id, :string)
        field(:name, :string)
        field(:occurred_at, :utc_datetime)
      end

      Repo.insert!(%Event{id: Ecto.UUID.generate(), name: ..., occurred_at: ...})

  The schema field is a plain `:string`, not `Ecto.UUID`: ClickHouse's
  `UUID` column round-trips through this adapter as the standard
  hyphenated text form (see `ChDriver.Protocol.NativeBlock.decode_uuid/1`),
  while `Ecto.UUID`'s own `dump/1` produces a raw 16-byte binary meant for
  Postgres-style binary UUID storage -- sent as a query parameter here,
  ClickHouse rejects it with `Cannot parse uuid`. So `Ecto.UUID.generate/0`
  is used directly as a plain string, assigned explicitly before insert,
  with no adapter-side autogeneration involved.

  Whichever id strategy is used, remember ClickHouse
  will not reject a duplicate: deduplication (if wanted at all) has to be
  handled either at the application level or via a ClickHouse-native
  mechanism (e.g. `ReplacingMergeTree`, `INSERT ... SELECT ... WHERE NOT
  EXISTS`), never assumed for free from `ORDER BY`/`PRIMARY KEY` the way
  it would be from a Postgres `PRIMARY KEY` constraint.
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
