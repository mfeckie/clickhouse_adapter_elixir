# Architecture

Internal design notes for `clickhouse_adapter_ecto`. This is not published
to Hex and not meant for adapter *users* -- if you're wiring up a `Repo`
against ClickHouse, read the module docs (`Ecto.Adapters.ClickHouse` and
friends) instead. This file exists for anyone maintaining or extending the
adapter itself.

## Module map

* `Ecto.Adapters.ClickHouse` -- the adapter entry point. Implements
  `Ecto.Adapter.Storage` and `Ecto.Adapter.Migration` directly; everything
  else comes from `use Ecto.Adapters.SQL, driver: :ch_driver`, which
  delegates SQL generation to `Connection`.
* `Ecto.Adapters.ClickHouse.Connection` -- implements
  `Ecto.Adapters.SQL.Connection`. Thin: query execution lives here,
  statement generation is delegated to `QueryBuilder` and `DDL`.
* `Ecto.Adapters.ClickHouse.QueryBuilder` -- `all/2`, `update_all/2`,
  `delete_all/1`, `insert/8`, `update/5`, `delete/5`, `explain_query/4`.
* `Ecto.Adapters.ClickHouse.Expression` -- clause and expression rendering
  (`SELECT`/`FROM`/`JOIN`/`WHERE`/`GROUP BY`/`HAVING`/`ORDER BY`/`LIMIT`/
  `OFFSET`, plus the general `expr/3` renderer). Split from `QueryBuilder`
  because the two change for different reasons: a new Ecto fragment or
  operator touches `Expression`, while `insert/8`'s on-conflict handling or
  `delete_all/1`'s scoping touches `QueryBuilder`. Neither file should grow
  for the other's reasons.
* `Ecto.Adapters.ClickHouse.DDL` -- `CREATE`/`DROP TABLE` generation for
  `Ecto.Migration`.
* `Ecto.Adapters.ClickHouse.Naming` -- identifier quoting and
  source-naming helpers, shared by `QueryBuilder`, `Expression`, and `DDL`
  so quoting logic isn't duplicated three ways.
* `Ecto.Adapters.ClickHouse.Migration` -- validated builders for
  ClickHouse-specific migration column types (`FixedString(N)`,
  `LowCardinality(T)`).
* `Ecto.Adapters.ClickHouse.Types.FixedString` -- the schema-side
  `Ecto.ParameterizedType` for `FixedString(N)`.

## `Ecto.Adapters.ClickHouse`

### Boolean type coercion

ClickHouse has no native boolean wire type. `UInt8` is the idiomatic
encoding for a `:boolean` Ecto field -- the same convention MyXQL follows
for MySQL's `TINYINT`-backed booleans. `ChDriver.Protocol.NativeBlock`
hands back the raw integer `0`/`1` for such a column rather than inventing
a driver-level boolean type, so the adapter has to coerce it.

Ecto's built-in `:boolean` type loader only accepts an actual `true`/
`false` term and raises otherwise. `loaders/2` is overridden for
`:boolean` to run `load_boolean/1` first, coercing the raw integer before
it reaches that built-in loader. This overrides the default `loaders/2`
that `use Ecto.Adapters.SQL` defines (`def loaders(_, type), do: [type]`,
i.e. no coercion at all).

`DateTime` columns need no equivalent override: `NativeBlock` decodes
ClickHouse's `DateTime` type directly into a UTC `DateTime.t()`, and
Ecto's built-in `:naive_datetime`/`:utc_datetime` loaders already accept a
UTC `DateTime.t()` as input (see `Ecto.Type.load/2`).

### `insert/6` override

ClickHouse's native protocol reports 0 rows / no affected-row count for a
successful `INSERT` -- there's no equivalent of MySQL/Postgres's "rows
affected". The default `Ecto.Adapters.SQL.struct/10` behavior (inherited
from `use Ecto.Adapters.SQL`) treats `num_rows: 0` as a stale/failed write,
which would incorrectly raise or return `{:error, :stale}` on every
successful insert. `insert/6` is overridden to sidestep that, and rejects
`:returning` up front since ClickHouse's `INSERT` has no `RETURNING`
clause.

### `update/6` and `delete/5` overrides

These are overridden (rather than left to the default `use
Ecto.Adapters.SQL` implementation) purely to dodge a spurious compiler
warning. The generated default does `sql = @conn.update(...)` /
`sql = @conn.delete(...)`, and since `Connection.update/5`/`delete/4`
always raise (ClickHouse has no synchronous `UPDATE`/`DELETE`), Elixir's
type checker infers their return type as `none()` and flags the pattern as
"will never match". Raising directly here, without going through a call
whose inferred return type is uninhabited, sidesteps that false positive.
User-facing behavior is identical either way.

### Storage implementation

`storage_up/1`/`storage_down/1` issue a plain `CREATE DATABASE`/
`DROP DATABASE` over a short-lived, unpooled `ChDriver` connection (see
`run_storage_query/2`), entirely separate from the repo's normal
connection pool (which may not even be started yet during
`mix ecto.create`). `storage_status/1` checks `system.databases`.

That maintenance connection always connects with `database: "default"`
regardless of the repo's configured target database: the target database
is exactly what's about to be created or dropped, and ClickHouse's
native-protocol handshake only uses `:database` to pick an
unqualified-name default for the session, not to require its existence --
so this is safe even when the target database doesn't exist yet
(`storage_up`) or has just been dropped (`storage_down`).

`quote_literal/1` (used to build the `WHERE name = '...'` literal for the
`system.databases` lookup) rejects rather than escapes: besides an
embedded `'` breaking out of the literal outright, a lone trailing `\`
would also be dangerous left unescaped -- ClickHouse string literals honor
backslash-escaping, so `'#{value}'` with `value` ending in an odd number
of backslashes would escape away the closing quote and leave the literal
unterminated instead of raising a clean parse error.

There's no ClickHouse equivalent of "does this role have CREATEDB" to
worry about, and no encoding/collation options to support (ClickHouse
databases don't have either).

### Migration locking

`lock_for_migrations/3` is a deliberate no-op that just calls the given
function directly. ClickHouse has no advisory-lock/row-lock primitive
comparable to Postgres's `pg_advisory_lock` (which MyXQL emulates with
`GET_LOCK`/`RELEASE_LOCK`) -- there's nothing to take a real lock *with*
here without inventing and maintaining a dedicated lock-row/lock-table
protocol. For a single-node dev setup (the only target of this phase)
concurrent migrators aren't a realistic concern. Revisit with a real
dedicated lock table (e.g. a `TinyLog` table holding one row per lock
name, acquired with an `INSERT` plus a uniqueness check) if/when
multi-node concurrent migrations become a real requirement.

## `Ecto.Adapters.ClickHouse.Connection`

### Parameter binding

SQL is generated the normal Ecto way with `?` placeholders (see
`Expression.expr/3`, `QueryBuilder.insert/8`), matching every other
`Ecto.Adapters.SQL.Connection` implementation. Rather than inlining the
corresponding runtime values as SQL literals, `%ChDriver.Query{}`'s
`DBConnection.Query` implementation (`ch_driver/lib/ch_driver/query.ex`)
rewrites each `?` into a ClickHouse native `{pN:Type}` parameter
placeholder and sends the value alongside the query through `ChDriver`'s
query-parameters wire mechanism (`ChDriver.Protocol.encode_query/2`). The
value's bytes never pass through the SQL text, so there's nothing to
escape, and no `?` inside a string literal or raw fragment can be mistaken
for a bind placeholder -- the one-time lexer driving this,
`ChDriver.Query.lex_placeholders/1`, tracks quoted regions while scanning.

ClickHouse's parameter mechanism has no type-independent way to express
`NULL` (see `ChDriver.Params.text/1`), so `nil` is the one exception: it's
inlined directly as the literal `NULL` token, which carries no injection
risk since it's a fixed constant.

`Connection` itself does no lexing/binding -- it builds a
`%ChDriver.Query{statement: sql}` and lets `DBConnection`'s normal
parse/encode/execute flow (driven by `Ecto.Adapters.SQL`'s own query
cache) handle it, once per distinct prepared query shape rather than on
every execute.

### `prepare_execute/5` vs `execute/4`

`prepare_execute/5` builds a fresh, never-parsed query struct.
`DBConnection.prepare_execute/4` runs it through
`DBConnection.Query.parse/2` (the one-time `?` lexer), then `encode/3`,
then `handle_execute/4`. The returned, now-parsed struct is what
`Ecto.Adapters.SQL`'s query cache holds onto and later passes back into
`execute/4` -- that's what skips re-parsing on every subsequent execution
of the same prepared query. `execute/4` only runs `encode/3` (using its
cached `param_names`) and `handle_execute/4`.

`query/4` has no cache to reuse a parsed struct from (mirrors `:nocache`
semantics), so it always goes through the full parse/encode/execute path.

### `stream/4` and the transaction limitation

`stream/4` builds a `%ChDriver.Stream{}` (see its moduledoc, and
`ChDriver.DBConnection`'s "Cursors" section, for how this stays genuinely
incremental -- one ClickHouse wire-protocol Data block at a time -- rather
than buffering the whole result first), mirroring every other
`Ecto.Adapters.SQL.Connection`'s `stream/4` (e.g. `Postgrex.Connection`,
which just calls `Postgrex.stream/4`).

`conn` is always already a checked-out `%DBConnection{conn_mode:
:transaction}` by the time this is called -- `Ecto.Adapters.SQL`'s
`reduce/6` (which backs `Repo.stream/2`) guards on exactly that mode
before ever reaching here, the same requirement every SQL adapter's
`Repo.stream/2` has (Postgres included).

**Known limitation:** unlike Postgres, `ChDriver.DBConnection` has no
`handle_begin/2` (ClickHouse's native protocol as used here has no session
transaction support), so `Repo.transaction/2` itself cannot succeed on
this adapter yet, which means `Repo.stream/2` cannot be driven end-to-end
through `Ecto.Repo`'s `transaction/2`. The `stream/4` function and the
underlying `ChDriver.Stream` machinery are fully real and independently
tested (`ch_driver/test/ch_driver/stream_test.exs`,
`clickhouse_adapter_ecto/test/integration/stream_test.exs`) via
`DBConnection.run/3` directly, which only needs a plain checkout, not a
transaction. Adding real ClickHouse session transaction support to unblock
`Repo.transaction/2`/`Repo.stream/2` end-to-end is tracked separately.

## `Ecto.Adapters.ClickHouse.DDL`

### Why `change/0` reversal is judged operation by operation

Ecto's `change/0` migrations rely on `Ecto.Migration`'s built-in reversal
(`create table(...)` -> `drop table(...)`, `add :col, :type` ->
`remove :col`, etc) to synthesize the `down` direction. Whether that's
safe to auto-generate for ClickHouse depends on whether the underlying
operation is synchronous/metadata-only or an asynchronous, potentially
lossy rewrite:

* `ALTER TABLE ... MODIFY ORDER BY` / partition key changes are unsafe:
  MergeTree's `ORDER BY`/`PARTITION BY` defines the on-disk sort order and
  physically reorganizes existing parts. There's no generic "undo" -- the
  old physical layout isn't recoverable from the new one -- and Ecto has
  no built-in reversal for this operation anyway.
* `ALTER TABLE ... MODIFY COLUMN <type>` (a real type change, not a
  widening no-op) is unsafe: it triggers an asynchronous background
  mutation that rewrites every existing part. Data can be irreversibly
  truncated or coerced during the rewrite (e.g. `String` -> `Int32` on
  non-numeric values), so mutating back to the old type does not restore
  the original bytes.
* Any `UPDATE`/`DELETE`-shaped mutation on existing rows is unsafe for the
  same reason: these are async, best-effort mutations over existing data,
  not metadata changes, and have no automatic inverse.

`execute_ddl/1` raises a specific `ArgumentError` if handed an
`{:alter, %Table{}, subcommands}` tuple that includes a `:modify`
subcommand, calling out that it's unsafe and must be written as explicit
`up/0`/`down/0`, rather than falling through to the generic "not
implemented" message.

### Why data-skipping indices don't get a migration DSL command

`Ecto.Migration.index/3` (`create index(...)`) models a Postgres/MySQL
B-tree-shaped index: a column list plus `unique:`/`using:`/`where:`.
ClickHouse's data-skipping indices (`minmax`, `set`, `bloom_filter`,
`ngrambf_v1`, `tokenbf_v1`, ...) are a different mechanism entirely -- an
arbitrary expression, a type with its own positional tuning parameters
(e.g. `bloom_filter(0.01)`), and a `GRANULARITY n`, used to skip whole
granules during a scan rather than to accelerate point lookups. None of
`index/3`'s fields map onto that shape, and stuffing
`type(params) GRANULARITY n` into `using:` would misrepresent `using:`'s
documented meaning (an index method name like `:gin`/`:hash`) for every
other adapter that reads it. So `execute_ddl/1` doesn't recognize
`{:create, %Index{}}` at all; it falls through to the generic clause that
raises and points at `execute/1`.

### Why projections are out of scope

A projection (`ALTER TABLE ... ADD PROJECTION`) defines an alternate
physical layout (its own sort order and/or aggregation) of the same table
data, materialized and kept in sync by ClickHouse in the background --
closer to a materialized view bolted onto the table than to an index. It
doesn't share data-skipping indices' comparatively simple
`ADD INDEX name expr TYPE type(params) GRANULARITY n` grammar (`ADD
PROJECTION` takes an arbitrary `SELECT`-shaped body), and nothing about it
is trivial enough to justify adapter-level support before a concrete use
case demands it.

### Why Kafka-ingestion pipelines get no migration DSL either

ClickHouse's standard Kafka ingestion pipeline is three separate pieces
wired together, none of which fit `Ecto.Migration.Table`'s column-list
DSL:

1. A target table (an ordinary MergeTree-family table) -- already fully
   supported by `create table(...)`.
2. A `Kafka`-engine source table, whose "columns" are the parsed message
   fields plus virtual columns (`_topic`, `_partition`, `_offset`,
   `_timestamp`, `_headers.name`/`_headers.value`) that ClickHouse injects
   and that no `Ecto.Migration.Table` column list could express anyway.
3. A materialized view (`CREATE MATERIALIZED VIEW mv_name TO target_table
   AS SELECT ... FROM kafka_table`) -- semantically a standing INSERT
   trigger that fires once per Kafka poll batch, not an
   on-demand-refreshed view.

`execute_ddl/1`'s `is_binary/1` clause already passes raw SQL strings
through verbatim -- the same mechanism relied on for `MODIFY ORDER BY`,
data-skipping indices, and projections above. Kafka table DDL and a view's
`AS SELECT ...` body are no less arbitrary than those, so adapter-level
sugar here would just be a second, narrower way to spell `execute/1` with
none of its generality.

Only the explicit `CREATE MATERIALIZED VIEW ... TO target_table AS
SELECT ...` form is supported/documented; the implicit-target-table form
(`CREATE MATERIALIZED VIEW ... ENGINE = ... AS SELECT ...`, where
ClickHouse creates and owns a hidden backing table) is out of scope. The
hidden table has no name a migration's `down/0` can address directly
(ClickHouse mangles it, e.g. `.inner.<uuid>`), which turns a clean,
explicit teardown into guesswork; requiring `TO target_table` keeps every
piece a migration creates addressable by the name that migration chose.

Creation order (`up/0`) matters: target table, then the Kafka source
table, then the materialized view. Only the Kafka table is a hard
requirement before the view -- `CREATE MATERIALIZED VIEW ... AS SELECT ...
FROM kafka_table` resolves and validates the `FROM` table's columns
immediately (`CREATE TABLE ... AS SELECT FROM <nonexistent>` fails with
`UNKNOWN_TABLE`), while the `TO target_table` name isn't validated until
the first insert. Creating the target table first anyway keeps a
consistent, unsurprising order and means the view is never live before
somewhere to write actually exists.

Teardown order (`down/0`) is the reverse, and not interchangeable:
materialized view, then Kafka source table, then target table. `DROP
TABLE` on the Kafka source table stops its background consumer
immediately and cleanly (the row in `system.kafka_consumers` disappears,
no entry lingers in `kafka-consumer-groups.sh --list`) regardless of what
else references it, so it never orphans a consumer group by itself. The
actual hazard is dropping the *target* table while the materialized view
and Kafka table are still live: ClickHouse allows the `DROP TABLE` on the
target with no error and no dependency check, but the view is left
silently pointing at nothing -- ingestion stalls with no exception
surfaced anywhere (not in `system.kafka_consumers.exceptions.text`, not in
the server log). Dropping the view first removes the trigger before
either table underneath it goes away, so there's no window where a poll
batch can fire into a broken pipeline.

### Why `Map(K, V)` gets no validated builder

Unlike `FixedString(N)`'s single integer parameter or
`LowCardinality(T)`'s single inner type, `Map(K, V)` has two independent
type parameters, and ClickHouse further restricts which types `K` may be
(a fixed set of scalar types -- `String`, the integer types,
`FixedString`, `UUID`, `LowCardinality(String)`, `Date`/`DateTime`, and
`Enum`) while `V` accepts nearly any type including nested `Array`/`Map`.
Building a builder that actually enforces that key restriction (rather
than silently accepting an eventual ClickHouse-side type error) is real,
ClickHouse-specific validation logic disproportionate to how rarely a
migration author reaches for `Map(K, V)` directly on a column versus
modeling the same data as a normal table. Revisit if a concrete use case
needs it.

### The `ORDER BY`/`PRIMARY KEY` footgun: how this was confirmed

The adapter docs state, as a plain caveat, that ClickHouse's `ORDER BY`/
`PRIMARY KEY` isn't a Postgres-style primary key. That claim was confirmed
empirically against a live ClickHouse server rather than assumed from
documentation alone -- see `test/integration/primary_key_semantics_test.exs`
for the test that pins this behavior. Two things were verified
specifically:

1. `create table(:things) do add :name, :string end`, with no
   `primary_key: false`, does not raise or silently produce a broken
   column. `Ecto.Migration` injects its own default
   `add :id, :bigserial, primary_key: true` column before this module ever
   sees the command list, exactly like it would for Postgres.
   `engine_clause/2` special-cases any `:add` column carrying
   `primary_key: true`: it becomes part of `ORDER BY`, `:bigserial` maps
   to `UInt64`, and the column is never wrapped in `Nullable(...)` (see
   `column_definition!/1`). The resulting `CREATE TABLE ... (id UInt64,
   name Nullable(String)) ENGINE = MergeTree ORDER BY (id)` is perfectly
   valid ClickHouse DDL, and the migration succeeds.
2. What actually breaks happens *after* `CREATE TABLE`, at insert time,
   and it's silent. `ORDER BY`/`PRIMARY KEY` in ClickHouse is a sparse
   sorting/indexing key used to skip granules during a scan -- it's never
   enforced as unique at insert time, and ClickHouse has no server-side
   autoincrement for `id` to fall back on the way a Postgres `bigserial`
   sequence would. This adapter doesn't synthesize autogeneration either
   (no `:on_conflict`/`:returning` support). So a schema using Ecto's
   default `@primary_key {:id, :id, autogenerate: true}` that omits `:id`
   from an insert -- the normal Postgres pattern of "let the database
   generate it" -- simply never sends a value for that column. ClickHouse
   fills it with the column type's default, `0` for `UInt64`, not a fresh
   unique value. Every row inserted this way lands on `id = 0`: all of
   them are accepted with no error, but they become indistinguishable by
   "primary key" from one another.

The schema field for an application-supplied id should be a plain
`:string`, not `Ecto.UUID`: ClickHouse's `UUID` column round-trips through
this adapter as the standard hyphenated text form (see
`ChDriver.Protocol.NativeBlock.decode_uuid/1`), while `Ecto.UUID`'s own
`dump/1` produces a raw 16-byte binary meant for Postgres-style binary
UUID storage -- sent as a query parameter, ClickHouse rejects it with
`Cannot parse uuid`. `Ecto.UUID.generate/0` is still useful, just used
directly as a plain string, assigned explicitly before insert.

## `Ecto.Adapters.ClickHouse.Expression`

### Why plain `INNER`/`LEFT JOIN` needs no extra qualifier

ClickHouse's ANSI-style `INNER`/`LEFT JOIN ... ON ...` needs no
`ALL`/`ANY` strictness qualifier for a plain equality `ON` condition
against the pinned `clickhouse/clickhouse-server:26.7` image used by this
repo's `docker-compose.yml`. ClickHouse defaults to `ALL` semantics (every
matching row pairing, standard SQL join behavior) unless a stricter
`join_default_strictness` setting or an explicit `ANY`/`ASOF`/`SEMI`
qualifier says otherwise, so the generated SQL stays exactly the
standard-SQL shape other Ecto adapters (Postgres, MyXQL) produce instead
of ClickHouse-specific syntax.

### `GROUP BY`/`HAVING` scope

`GROUP BY` is structurally the same shape `ORDER BY` already handles (a
`%Ecto.Query.ByExpr{}` per `group_by(...)` call, each wrapping a list of
expressions), minus the `{direction, expr}` wrapper `ORDER BY` has --
`group_by/3` has no notion of ascending/descending. SQL-standard `GROUPING
SETS`/`ROLLUP`/`CUBE` and ClickHouse's own `GROUP BY ... WITH
TOTALS`/`WITH ROLLUP`/`WITH CUBE` modifiers aren't guarded against
anywhere because `Ecto.Query`'s `group_by/3` doesn't expose a way to
express them at all -- there's nothing here that could reach those code
paths in the first place.

`HAVING` is rendered with exactly the same `boolean/4` clause-composition
machinery `WHERE` uses: `HAVING`'s condition is the same kind of
`%Ecto.Query.BooleanExpr{}` tree `WHERE` gets, just evaluated after `GROUP
BY` instead of before it, so there's no ClickHouse-specific dialect
difference to account for.

## `Ecto.Adapters.ClickHouse.QueryBuilder`

### Why `delete_all/1` is scoped so narrowly

ClickHouse has no synchronous `DELETE`; row removal goes through the
`ALTER TABLE ... DELETE WHERE ...` mutation, which is queued and applied
in the background by default. That mutation accepts a
`SETTINGS mutations_sync = 1` clause that makes the issuing client block
until the mutation has actually been applied locally before the query
returns. That's exactly what's needed to make
`Ecto.Migration.SchemaMigration`'s `down/4` (`repo.delete_all(from m in
"schema_migrations", where: m.version == ^v)`) behave synchronously enough
for `Ecto.Migrator.run(repo, path, :down, ...)` to work: insert the row
(`up`), delete it and immediately have it gone (`down`), no polling or
manual mutation-tracking required.

This is a mutation under the hood, not a real transactional `DELETE`, so
the scope is narrow, limited to what maps cleanly onto a single
`ALTER TABLE ... DELETE WHERE <cond>`: a single source table (no joins),
no `LIMIT`/`OFFSET` (mutations have no concept of either).

`mutations_sync = 1` only waits for the mutation to finish on the node
that received the query -- on a replicated/multi-node cluster you'd want
`mutations_sync = 2` to wait for all replicas. This adapter only targets
single-node ClickHouse, so `1` is sufficient and cheaper. General
multi-row bulk-delete workloads on large MergeTree tables should still
prefer an unsynchronized `ALTER TABLE ... DELETE` (fire-and-forget) via a
raw query instead of this -- forcing every mutation to block until fully
applied is fine for a handful of `schema_migrations` bookkeeping rows, but
would be a real throughput/latency problem at scale.

Unlike `all/2`, `ALTER TABLE ... DELETE` has no `FROM ... AS alias` clause
to declare a table alias against -- it's always exactly one bare table
name. `delete_all/1` builds a one-element sources tuple with an empty
alias so `Expression.where/2`/`Expression.expr/3` emit unqualified
`"version"` instead of `s0."version"` (which ClickHouse would reject:
"Missing columns: 's0.version'" -- there's no `s0` in scope). `ALTER TABLE
... DELETE` also requires a `WHERE` clause (unlike a plain SQL `DELETE`,
ClickHouse has no unconditional-delete-everything form of the mutation),
so a query with no `where(...)` at all falls back to `WHERE 1` to match
`Repo.delete_all(query)` semantics with no filter.

### Why `update/5` and `delete/4` exist as always-raising functions

These are only reachable via a direct call to `QueryBuilder` (e.g. from a
raw script) -- `Ecto.Adapter.Schema`'s `update/6` and `delete/5` in
`Ecto.Adapters.ClickHouse` are overridden to raise directly instead of
going through these, so `Ecto.Repo.update!/1`/`delete!/1` never hit them.
That indirection exists to dodge a spurious "will never match" type-checker
warning caused by these always-raising functions inferring a `none()`
return type -- see the note under `Ecto.Adapters.ClickHouse`'s `update/6`
override above.
