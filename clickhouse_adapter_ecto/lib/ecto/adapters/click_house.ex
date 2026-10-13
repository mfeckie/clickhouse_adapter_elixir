defmodule Ecto.Adapters.ClickHouse do
  @moduledoc """
  An `Ecto.Adapters.SQL`-based adapter for ClickHouse, talking to it over
  its native TCP protocol via `ChDriver`.

  ## Usage

  Point a repo's `adapter` at this module and configure it like any other
  `Ecto.Repo`:

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
      end

      config :my_app, MyApp.Repo,
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: ""

      # So the mix ecto.* tasks know which repo to act on.
      config :my_app, ecto_repos: [MyApp.Repo]

  Then start the repo under your application's supervision tree, which is
  what actually starts the connection pool:

      # lib/my_app/application.ex
      def start(_type, _args) do
        children = [
          MyApp.Repo
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
      end

  Without it, every query fails with `could not lookup Ecto repo
  MyApp.Repo because it was not started or it does not exist`.

  ## Migrations

  `mix ecto.gen.migration` and `mix ecto.migrate` work as usual.
  `create table(...)` and `drop table(...)` with plain `:add` columns are
  supported; ClickHouse has no transactional DDL, so
  `supports_ddl_transaction?/0` returns `false`. See
  `Ecto.Adapters.ClickHouse.DDL` for the full picture of what's supported,
  including `:alter`, indexes, and constraints (none of which are, yet).

  ClickHouse's `ORDER BY`/`PRIMARY KEY` is not a Postgres-style primary
  key -- it's a sort/skip index for scans, never enforced as unique, and
  ClickHouse has no autoincrement. Ecto's default
  `add :id, :bigserial, primary_key: true` still produces valid DDL, but
  leaving `:id` out of an insert (the usual "let the database generate it"
  pattern) silently writes `0` for every row instead of a fresh value.
  Give tables an explicit id and sort key instead:

      create table(:events, primary_key: false, options: "ENGINE = MergeTree ORDER BY id") do
        add(:id, :uuid, primary_key: true)
        add(:name, :string)
        add(:occurred_at, :utc_datetime)
      end

  paired with a schema that supplies `:id` itself:

      @primary_key false
      schema "events" do
        field(:id, :string)
        field(:name, :string)
        field(:occurred_at, :utc_datetime)
      end

      Repo.insert!(%Event{id: Ecto.UUID.generate(), name: "signup", occurred_at: DateTime.utc_now(:second)})

  The `:id` field is a plain `:string`, not `Ecto.UUID` -- ClickHouse's
  `UUID` column round-trips as a hyphenated text string, while
  `Ecto.UUID`'s `dump/1` produces a raw binary ClickHouse rejects.
  `Ecto.UUID.generate/0` still works fine for generating the value itself.

  ## Replicated clusters

  `mix ecto.create` runs a plain `CREATE DATABASE`, which creates an
  `Atomic` database on whichever server the connection reached. For a
  replicated cluster, set the database engine and cluster so it is created
  on every replica:

      config :my_app, MyApp.Repo,
        database: "my_app",
        database_engine: "Replicated",
        cluster: "{cluster}"

  renders `CREATE DATABASE IF NOT EXISTS "my_app" ON CLUSTER '{cluster}'
  ENGINE = Replicated`, and `mix ecto.drop` renders `DROP DATABASE IF
  EXISTS "my_app" ON CLUSTER '{cluster}' SYNC`. Both options are optional
  and independent. With `:cluster` set, `mix ecto.create` and `mix
  ecto.drop` are safe to re-run: a re-run creates or drops the database on
  replicas an earlier, partial run missed. They report `already up` or
  `already down` based on the replica they connected to.

  ON CLUSTER waits for every host. `:cluster_ddl_timeout` (milliseconds,
  default `60_000`) caps that wait; past it, the storage function returns
  ClickHouse's "not finished on N hosts" error, and the hosts that were
  down run the queued DDL when they come back.

  A `Replicated` database replicates DDL, but a plain `MergeTree` table in
  it still keeps its data on one replica. Declare tables with
  `Replicated*MergeTree` engines (no arguments needed inside a `Replicated`
  database), and set `default_table_engine: "ReplicatedMergeTree"` on the
  repo so `schema_migrations` and other tables without an explicit engine
  replicate too. Like any repo option, it can come from config,
  `Repo.start_link/1` or the repo's `init/2`.

  `Repo.delete_all/2` waits for every replica (see
  `Ecto.Adapters.ClickHouse.QueryBuilder`). If a replica is down, it logs a
  warning and returns once the live replicas have applied the delete; the
  down replica applies it when it returns.

  Migrations need every replica up. In a `Replicated` database each DDL
  statement, including the `CREATE TABLE IF NOT EXISTS schema_migrations`
  that every `mix ecto.migrate` and `mix ecto.rollback` starts with, waits
  for all replicas.

  `storage_up/1`, `storage_down/1` and `storage_status/1` connect to the
  `:maintenance_database` (default `"default"`), since the target database
  may not exist yet. Point it at a database the user can access if it has
  no grants on `default`.

  Migrations take no lock (ClickHouse has no lock primitive to build one
  on), so run them from a single place, such as one release task or job,
  rather than from every node at boot.

  ## Querying

      import Ecto.Query

      MyApp.Repo.all(from e in Event, where: e.name == "signup", order_by: e.occurred_at)

  ## What's not supported

    * `Repo.update!/1` and `Repo.delete!/1` -- ClickHouse mutates existing
      data via the asynchronous `ALTER TABLE ... UPDATE`/`DELETE`
      statements, not synchronous SQL. Issue those directly as raw queries
      if you need them.
    * `:on_conflict` (upserts) and `:returning` on insert -- ClickHouse's
      `INSERT` has neither. Use `ReplacingMergeTree`/`CollapsingMergeTree`
      table engines for upsert-like behavior instead.
    * Real transactions (`Repo.transaction/2`), and by extension
      `Repo.stream/2` -- ClickHouse's native protocol as used here has no
      session transaction support. See `Ecto.Adapters.ClickHouse.Connection`'s
      `stream/4` for a workaround.
    * Joins, `LIMIT`, and `OFFSET` in `delete_all/2` -- only a plain
      `WHERE` against a single table.
    * `:alter` migrations (add/remove/modify column), indexes, and
      constraints.
    * `DISTINCT`, window functions, and set operations in queries.

  See `Ecto.Adapters.ClickHouse.Connection`, `.DDL`, and `.Expression` for
  exactly which query and DDL shapes are supported.
  """

  use Ecto.Adapters.SQL, driver: :ch_driver

  @behaviour Ecto.Adapter.Storage

  @default_cluster_ddl_timeout 60_000

  # ecto_sql doesn't mark init/1 overridable. Overriding it is the only way
  # to see the repo's full runtime config (start_link/1 opts, init/2,
  # dynamic repos) when execute_ddl/3 runs, since that gets only adapter
  # meta and repo.config/0 reads app env alone.
  defoverridable init: 1

  @impl Ecto.Adapter
  def init(config) do
    {:ok, child_spec, meta} = super(config)
    engine = string_opt!(config, :default_table_engine)
    {:ok, child_spec, Map.put(meta, :default_table_engine, engine)}
  end

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

  # Ecto creates schema_migrations itself, so a repo-level default is the
  # only way to give it a Replicated engine.
  @impl Ecto.Adapter.Migration
  def execute_ddl(meta, {command, %Ecto.Migration.Table{} = table, columns}, opts)
      when command in [:create, :create_if_not_exists] do
    table = default_table_engine(table, Map.get(meta, :default_table_engine))
    super(meta, {command, table, columns}, opts)
  end

  def execute_ddl(meta, definition, opts), do: super(meta, definition, opts)

  @doc false
  def default_table_engine(%Ecto.Migration.Table{engine: nil, options: options} = table, engine)
      when is_binary(engine) do
    if Ecto.Adapters.ClickHouse.DDL.options_set_engine?(options),
      do: table,
      else: %{table | engine: engine}
  end

  def default_table_engine(table, _engine), do: table

  ## Storage -- see moduledoc. `opts` here is the repo's full config
  ## (`:hostname`, `:port`, `:database`, `:username`, `:password`, etc, as
  ## passed to `Repo.start_link/1`/read from `config.exs`) -- exactly what
  ## `ChDriver.start_link/1` expects, once `:database` is swapped out below.

  # With a :cluster, the existence check only sees the replica we connected
  # to, so CREATE runs (IF NOT EXISTS, ON CLUSTER) even when that replica
  # already has the database: a re-run then fills in replicas an earlier,
  # partial run missed.
  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    database = fetch_database!(opts)

    with {:ok, exists?} <- database_exists?(database, opts) do
      if exists? and string_opt!(opts, :cluster) == nil do
        {:error, :already_up}
      else
        case run_storage_query(create_database_sql(database, opts), opts) do
          {:ok, _} when exists? -> {:error, :already_up}
          {:ok, _} -> :ok
          {:error, error} -> {:error, Exception.message(error)}
        end
      end
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    database = fetch_database!(opts)

    if string_opt!(opts, :cluster),
      do: cluster_storage_down(database, opts),
      else: local_storage_down(database, opts)
  end

  # DROP ... IF EXISTS ON CLUSTER succeeds whether or not a given replica
  # has the database, so :already_down comes from the connected replica.
  defp cluster_storage_down(database, opts) do
    with {:ok, exists?} <- database_exists?(database, opts) do
      case run_storage_query(drop_database_sql(database, opts), opts) do
        {:ok, _} when exists? -> :ok
        {:ok, _} -> {:error, :already_down}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  defp local_storage_down(database, opts) do
    case run_storage_query(drop_database_sql(database, opts), opts) do
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

    case run_storage_query(database_exists_sql(database), opts) do
      {:ok, %{num_rows: 0}} -> :down
      {:ok, %{num_rows: n}} when n > 0 -> :up
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def create_database_sql(database, opts) do
    engine =
      case string_opt!(opts, :database_engine) do
        nil -> ""
        engine -> " ENGINE = " <> engine
      end

    IO.iodata_to_binary([
      "CREATE DATABASE ",
      if(string_opt!(opts, :cluster), do: "IF NOT EXISTS ", else: ""),
      Ecto.Adapters.ClickHouse.Naming.quote_name(database),
      on_cluster(opts),
      engine
    ])
  end

  # SYNC waits for the drop to finish, Keeper metadata included, so an
  # immediate re-create (mix ecto.reset) doesn't collide with leftovers.
  @doc false
  def drop_database_sql(database, opts) do
    IO.iodata_to_binary([
      "DROP DATABASE ",
      if(string_opt!(opts, :cluster), do: "IF EXISTS ", else: ""),
      Ecto.Adapters.ClickHouse.Naming.quote_name(database),
      on_cluster(opts),
      " SYNC"
    ])
  end

  # ON CLUSTER waits for every host, by default for 180s, well past
  # DBConnection's 15s query timeout. Bound the wait server-side so the
  # client gets ClickHouse's own "not finished on N hosts" error instead of
  # giving up while the DDL keeps running. The connection's recv_timeout
  # needs no change: the server keeps sending packets while it waits.
  @doc false
  def storage_query_opts(opts) do
    case string_opt!(opts, :cluster) do
      nil ->
        []

      _cluster ->
        timeout = Keyword.get(opts, :cluster_ddl_timeout, @default_cluster_ddl_timeout)

        unless is_integer(timeout) and timeout > 0 do
          raise ArgumentError,
                ":cluster_ddl_timeout must be a positive integer (milliseconds), " <>
                  "got: #{inspect(timeout)}"
        end

        [
          settings: [
            {"distributed_ddl_task_timeout", Integer.to_string(div(timeout + 999, 1000))}
          ],
          timeout: timeout + 10_000
        ]
    end
  end

  # A string literal rather than an identifier so macros like '{cluster}' expand.
  defp on_cluster(opts) do
    case string_opt!(opts, :cluster) do
      nil -> ""
      cluster -> " ON CLUSTER " <> quote_literal(cluster, ":cluster")
    end
  end

  defp string_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError, "#{inspect(key)} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp database_exists?(database, opts) do
    case run_storage_query(database_exists_sql(database), opts) do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp database_exists_sql(database),
    do: "SELECT 1 FROM system.databases WHERE name = " <> quote_literal(database, "database name")

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
  # yet, e.g. during `mix ecto.create`). Always connects with `database:`
  # set to `:maintenance_database` (default `"default"`) regardless of the
  # repo's configured target database: that
  # target database is exactly what we may be about to create or drop, and
  # ClickHouse's native-protocol handshake only uses `:database` to pick an
  # *unqualified-name* default for the session, not to require its
  # existence -- so this is safe even when the target database doesn't
  # exist yet (storage_up) or has just been dropped (storage_down).
  defp run_storage_query(sql, opts) do
    connect_opts =
      opts
      |> Keyword.take([:hostname, :port, :username, :password, :connect_timeout, :recv_timeout])
      |> Keyword.put(:database, Keyword.get(opts, :maintenance_database, "default"))

    case ChDriver.start_link(connect_opts) do
      {:ok, conn} ->
        try do
          ChDriver.query(conn, sql, [], storage_query_opts(opts))
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
  defp quote_literal(value, what) do
    if String.contains?(value, "'") or String.contains?(value, "\\") do
      raise ArgumentError, "bad #{what} #{inspect(value)} (' and \\ are not permitted)"
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
  # lock-row/lock-table protocol ourselves. A lock table wouldn't help on a
  # replicated cluster either, since replicas see each other's inserts
  # asynchronously. So this is a deliberate, documented no-op (see the
  # moduledoc's "Replicated clusters" section): just run the function.
  # Revisit with a real dedicated lock table (e.g. a `TinyLog`
  # table holding one row per lock name, acquired with an `INSERT` + a
  # uniqueness check) if/when multi-node concurrent migrations become a
  # real requirement.
  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _opts, fun), do: fun.()
end
