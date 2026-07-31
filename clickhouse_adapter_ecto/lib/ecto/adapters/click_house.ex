defmodule Ecto.Adapters.ClickHouse do
  @moduledoc """
  A minimal `Ecto.Adapters.SQL`-based adapter for ClickHouse, backed by
  `ChDriver` (a native-protocol `DBConnection` driver).

  This module wires `Ecto.Adapters.SQL` (which provides `Ecto.Adapter`,
  `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`, and
  `Ecto.Adapter.Transaction` for free, delegating SQL generation to
  `Ecto.Adapters.ClickHouse.Connection`) up to `ChDriver`.

  ## Scope of this phase

  This adapter currently targets basic `SELECT`/`INSERT` round-trips through
  a real `Ecto.Repo` -- see `Ecto.Adapters.ClickHouse.Connection`'s
  moduledoc for exactly which query shapes are supported.

  ## Storage (`mix ecto.create` / `mix ecto.drop`)

  `Ecto.Adapter.Storage` is implemented: `storage_up/1` and `storage_down/1`
  issue a plain `CREATE DATABASE`/`DROP DATABASE` over a short-lived
  maintenance connection (see `run_storage_query/2`), and `storage_status/1`
  checks `system.databases`. There is no ClickHouse equivalent of "does this
  role have CREATEDB" to worry about, and no encoding/collation options are
  supported (ClickHouse databases don't have either).

  ## Migrations (`mix ecto.migrate`)

  `Ecto.Adapter.Migration` is implemented well enough for straightforward
  migrations to run: `supports_ddl_transaction?/0` returns `false`
  (ClickHouse has no transactional DDL), and `lock_for_migrations/3` is a
  **deliberate no-op** that just calls the given function directly -- see
  its doc below for why. `Ecto.Adapters.ClickHouse.Connection`'s `execute_ddl/1`
  turns `create table(...)`/`drop table(...)` into `CREATE TABLE`/`DROP
  TABLE` (see that module's `## DDL` section for exactly what's supported
  and how the `ENGINE`/`ORDER BY` clause is chosen), which is what lets
  `Ecto.Migrator` create and populate `schema_migrations` automatically.

  `mix ecto.rollback` / `Ecto.Migrator.run(repo, path, :down, ...)` **is**
  supported for the common case: a `change/0` migration doing
  `create table(...)` auto-reverses to `drop table(...)` cleanly (both are
  synchronous, metadata-only DDL), and the `schema_migrations` bookkeeping
  row removal that Ecto.Migration.SchemaMigration's `down/4` issues via
  `Repo.delete_all/2` is handled by
  `Ecto.Adapters.ClickHouse.Connection`'s `delete_all/1`, which translates it
  into an `ALTER TABLE ... DELETE WHERE ... SETTINGS mutations_sync = 1`
  mutation that blocks until the row is actually gone, so the migrator's
  post-delete state is correct with no polling. See
  `Connection`'s moduledoc for exactly how narrowly that `delete_all` support
  is scoped (single table, no joins/LIMIT/OFFSET).

  Not supported: `:alter` (existing migrations that add/remove/modify
  columns), indexes, and constraints -- see
  `Ecto.Adapters.ClickHouse.Connection`'s `## DDL` moduledoc section for the
  full breakdown of which DDL operations are safe to auto-reverse via
  `change/0` (create/drop table; add/remove column, once `:alter` support
  lands) versus which are genuinely unsafe and must be written as explicit
  `up/0` + `down/0` (column type changes via `MODIFY COLUMN`, `ORDER BY`/
  partition key changes, and any `UPDATE`/`DELETE`-shaped data mutation).
  `execute_ddl/1` raises a specific, actionable error if asked to
  auto-generate DDL for an unsafe `:modify` column-type change.
  """

  use Ecto.Adapters.SQL, driver: :ch_driver

  @behaviour Ecto.Adapter.Storage

  ## Type loading -- ClickHouse has no native boolean wire type; `UInt8` is
  ## the idiomatic encoding for a `:boolean` Ecto field (the same convention
  ## MyXQL follows for MySQL's TINYINT-backed booleans), so
  ## `ChDriver.Protocol.NativeBlock` hands back the raw integer `0`/`1` for
  ## such a column (see that module's moduledoc) rather than inventing a
  ## driver-level boolean type. Ecto's own built-in `:boolean` type loader
  ## only accepts an actual `true`/`false` term and raises otherwise, so this
  ## coerces the raw integer *before* it reaches that built-in loader --
  ## overriding the `loaders/2` that `use Ecto.Adapters.SQL` defines by
  ## default (`def loaders(_, type), do: [type]`, i.e. no coercion at all).
  ##
  ## `DateTime` columns need no equivalent override: `NativeBlock` decodes
  ## ClickHouse's `DateTime` type directly into a UTC `DateTime.t()`,
  ## and Ecto's built-in `:naive_datetime`
  ## / `:utc_datetime` loaders already accept a UTC `DateTime.t()` as input
  ## (see `Ecto.Type.load/2`), so the default `loaders/2` clause below is
  ## sufficient for both.
  @impl true
  def loaders(:boolean, type), do: [&load_boolean/1, type]
  def loaders(_primitive_type, type), do: [type]

  defp load_boolean(0), do: {:ok, false}
  defp load_boolean(1), do: {:ok, true}
  defp load_boolean(other), do: {:ok, other}

  ## Schema -- insert/6 is overridden because ClickHouse's native protocol
  ## reports 0 rows/no affected-row count for a successful INSERT (there is
  ## no equivalent of MySQL/Postgres's "rows affected"), so the default
  ## `Ecto.Adapters.SQL.struct/10` behaviour inherited from `use
  ## Ecto.Adapters.SQL` -- which treats `num_rows: 0` as a stale/failed
  ## write -- would incorrectly raise/`{:error, :stale}` on every successful
  ## insert. `:returning` is rejected up front since ClickHouse's INSERT has
  ## no RETURNING clause (see `Ecto.Adapters.ClickHouse.Connection.insert/8`).
  @impl Ecto.Adapter.Schema
  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    if returning != [] do
      raise ArgumentError,
            "the ClickHouse adapter does not support :returning / read_after_writes fields " <>
              "-- ClickHouse's INSERT has no RETURNING clause"
    end

    %{source: source, prefix: prefix} = schema_meta
    {fields, values} = :lists.unzip(params)
    sql = @conn.insert(prefix, source, fields, [fields], on_conflict, returning, [])

    case Ecto.Adapters.SQL.query(adapter_meta, sql, values, opts) do
      {:ok, _result} ->
        {:ok, []}

      {:error, err} ->
        case @conn.to_constraints(err, source: source) do
          [] -> raise err
          constraints -> {:invalid, constraints}
        end
    end
  end

  ## `update/6` and `delete/5` are overridden (rather than left to the
  ## default implementation `use Ecto.Adapters.SQL` generates) purely to
  ## dodge a spurious compiler warning: the generated default does
  ## `sql = @conn.update(...)` / `sql = @conn.delete(...)`, and since
  ## `Connection.update/5`/`delete/4` always raise (ClickHouse has no
  ## synchronous UPDATE/DELETE -- see their docs), Elixir's type checker
  ## infers their return type as `none()` and flags that pattern as "will
  ## never match". Raising directly here, without going through a call
  ## whose inferred return type is uninhabited, sidesteps that false
  ## positive. The user-facing behavior (a clear ArgumentError explaining
  ## why) is unchanged either way.
  @impl Ecto.Adapter.Schema
  def update(_adapter_meta, _schema_meta, _params, _filters, _returning, _opts) do
    raise ArgumentError,
          "the ClickHouse adapter does not support UPDATE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... UPDATE` statement, not a synchronous SQL " <>
            "UPDATE -- issue an ALTER TABLE mutation directly via a raw query if you need this"
  end

  @impl Ecto.Adapter.Schema
  def delete(_adapter_meta, _schema_meta, _filters, _returning, _opts) do
    raise ArgumentError,
          "the ClickHouse adapter does not support DELETE: ClickHouse mutates existing data " <>
            "via the asynchronous `ALTER TABLE ... DELETE` statement, not a synchronous SQL " <>
            "DELETE -- issue an ALTER TABLE mutation directly via a raw query if you need this"
  end

  ## Storage -- see moduledoc. `opts` here is the repo's full config
  ## (`:hostname`, `:port`, `:database`, `:username`, `:password`, etc, as
  ## passed to `Repo.start_link/1`/read from `config.exs`) -- exactly what
  ## `ChDriver.start_link/1` expects, once `:database` is swapped out below.

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    database = fetch_database!(opts)

    case run_storage_query(
           "SELECT 1 FROM system.databases WHERE name = " <> quote_literal(database),
           opts
         ) do
      {:ok, %{num_rows: n}} when n > 0 ->
        {:error, :already_up}

      {:ok, _} ->
        case run_storage_query(
               ~s(CREATE DATABASE #{Ecto.Adapters.ClickHouse.Naming.quote_name(database)}),
               opts
             ) do
          {:ok, _} -> :ok
          {:error, error} -> {:error, Exception.message(error)}
        end

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    database = fetch_database!(opts)

    case run_storage_query(
           ~s(DROP DATABASE #{Ecto.Adapters.ClickHouse.Naming.quote_name(database)}),
           opts
         ) do
      {:ok, _} ->
        :ok

      {:error, %ChDriver.Error{message: message}} ->
        if message =~ ~r/does(?:n't| not) exist|unknown database/i do
          {:error, :already_down}
        else
          {:error, message}
        end

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    database = fetch_database!(opts)

    case run_storage_query(
           "SELECT 1 FROM system.databases WHERE name = " <> quote_literal(database),
           opts
         ) do
      {:ok, %{num_rows: 0}} -> :down
      {:ok, %{num_rows: n}} when n > 0 -> :up
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_database!(opts) do
    case Keyword.fetch(opts, :database) do
      {:ok, database} when is_binary(database) ->
        database

      _ ->
        raise ArgumentError, "storage_up/storage_down/storage_status require a :database option"
    end
  end

  # A short-lived, unpooled ChDriver connection used only for
  # CREATE/DROP/system.databases maintenance queries -- entirely separate
  # from the Repo's normal connection pool (which may not even be started
  # yet, e.g. during `mix ecto.create`). Always connects with `database:
  # "default"` regardless of the repo's configured target database: that
  # target database is exactly what we may be about to create or drop, and
  # ClickHouse's native-protocol handshake only uses `:database` to pick an
  # *unqualified-name* default for the session, not to require its
  # existence -- so this is safe even when the target database doesn't
  # exist yet (storage_up) or has just been dropped (storage_down).
  defp run_storage_query(sql, opts) do
    connect_opts =
      opts
      |> Keyword.take([:hostname, :port, :username, :password, :connect_timeout, :recv_timeout])
      |> Keyword.put(:database, "default")

    case ChDriver.start_link(connect_opts) do
      {:ok, conn} ->
        try do
          ChDriver.query(conn, sql)
        after
          GenServer.stop(conn)
        end

      {:error, _} = error ->
        error
    end
  end

  # Used to build a raw single-quoted string literal for a WHERE clause
  # (`system.databases` lookup), not an identifier. Reject rather than
  # escape: besides an embedded `'` breaking out of the literal outright, a
  # lone trailing `\` would also be dangerous left unescaped -- ClickHouse
  # string literals honor backslash-escaping, so `'#{value}'` with `value`
  # ending in an odd number of backslashes would escape away the closing
  # quote and leave the literal unterminated instead of raising a clean
  # parse error.
  defp quote_literal(value) do
    if String.contains?(value, "'") or String.contains?(value, "\\") do
      raise ArgumentError, "bad database name #{inspect(value)} (' and \\ are not permitted)"
    end

    "'" <> value <> "'"
  end

  ## Migration -- see moduledoc.
  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: false

  # ClickHouse has no advisory-lock/row-lock primitive comparable to
  # Postgres's `pg_advisory_lock` (which MyXQL emulates with
  # `GET_LOCK`/`RELEASE_LOCK`) -- there is nothing to take a real lock
  # *with* here without inventing and maintaining a dedicated
  # lock-row/lock-table protocol ourselves. For a single-node dev setup (the
  # only target of this phase) concurrent migrators aren't a realistic
  # concern, so this is a deliberate, documented no-op: just run the
  # function. Revisit with a real dedicated lock table (e.g. a `TinyLog`
  # table holding one row per lock name, acquired with an `INSERT` + a
  # uniqueness check) if/when multi-node concurrent migrations become a
  # real requirement.
  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _opts, fun), do: fun.()
end
