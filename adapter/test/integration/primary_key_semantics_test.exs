defmodule Ecto.Adapters.ClickHouse.PrimaryKeySemanticsTest do
  @moduledoc """
  End-to-end integration tests against a *live* ClickHouse instance (see
  `adapter/docker-compose.yml`) probing exactly what happens with
  `create table(...)`'s primary-key handling -- the single biggest footgun
  for anyone coming from Postgres/MySQL, per `Ecto.Adapters.ClickHouse.DDL`'s
  moduledoc.

  ClickHouse has no auto-increment and no unique-index enforcement at
  insert time: `ORDER BY` (optionally narrowed by a separate `PRIMARY KEY`
  clause, which must be a prefix of `ORDER BY`) is a sparse sorting/
  indexing key used to skip granules during a scan, not a uniqueness
  constraint. Duplicate "primary key" values are accepted silently.

  Empirically confirmed here (see each test):

    * Ecto's *default* auto-id behavior -- `create table(:things) do add
      :name, :string end` with no `primary_key: false` -- implicitly adds
      an `:id, :bigserial, primary_key: true` column. This adapter's
      `Ecto.Adapters.ClickHouse.DDL.engine_clause/2` already special-cases
      any `:add` column carrying `primary_key: true`: it becomes part of
      the `ORDER BY` clause of an implicit `ENGINE = MergeTree`, `:bigserial`
      maps to `UInt64` (see `column_type!/1`), and a `primary_key: true`
      column is never wrapped in `Nullable(...)` regardless of `:null`.
      So the DDL itself is generated correctly and `CREATE TABLE` succeeds
      -- there is no crash, no silently-broken column.
    * BUT ClickHouse has no server-side autoincrement, and this adapter
      does not synthesize one client-side either (no `:on_conflict`/
      `:returning` support, no adapter-level `autogenerate/1`). A schema
      with the default `@primary_key {:id, :id, autogenerate: true}` that
      omits `:id` from an insert (letting "the database" generate it, as
      it would on Postgres) simply never sends a value for that column --
      ClickHouse fills it with the column type's default (`0` for
      `UInt64`), not a fresh unique value. Every such insert collides on
      `id = 0`: the table still accepts all the rows (no uniqueness
      enforcement), but every row this "worked as on Postgres" pattern
      inserts is indistinguishable from every other by primary key.
    * The documented, correct pattern -- `primary_key: false` plus an
      explicit `options: "ENGINE = ... ORDER BY (...)"` on `table/2`, with
      `:id` supplied by the application (e.g. `Ecto.UUID.generate/0`,
      `System.unique_integer/1`, or a natural key) -- round-trips cleanly
      through a plain `Repo.insert!/1` and, unlike the naive pattern,
      actually distinguishes rows.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  # The NAIVE pattern: no `primary_key: false`, so `Ecto.Migration` injects
  # the default `add :id, :bigserial, primary_key: true` column for us,
  # exactly as it would for Postgres/MySQL.
  defmodule CreateThingsNaive do
    use Ecto.Migration

    def change do
      create table(:things_naive) do
        add(:name, :string)
      end
    end
  end

  # The DOCUMENTED, correct pattern: `primary_key: false` + an explicit
  # `ORDER BY`/`ENGINE` via `options:`, with the id supplied by the
  # application rather than relying on nonexistent autoincrement.
  defmodule CreateThingsCorrect do
    use Ecto.Migration

    def change do
      create table(:things_correct, primary_key: false, options: "ENGINE = MergeTree ORDER BY id") do
        add(:id, :uuid, primary_key: true)
        add(:name, :string)
      end
    end
  end

  defmodule ThingCorrect do
    use Ecto.Schema

    @primary_key false
    schema "things_correct" do
      field(:id, :string)
      field(:name, :string)
    end
  end

  defp start_ddl_conn! do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    ddl_conn
  end

  defp start_repo! do
    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

    :ok
  end

  test "the naive default-primary-key pattern creates a real, working table (no crash, no misleading column)" do
    ddl_conn = start_ddl_conn!()
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_naive")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
    start_repo!()

    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateThingsNaive}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # The table was actually created, with the expected column shape: `id
    # UInt64` (from :bigserial), non-nullable (primary-key columns are
    # never wrapped in Nullable), ordered by it.
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns " <>
          "WHERE database = currentDatabase() AND table = 'things_naive' ORDER BY name"
      )

    assert rows == [["id", "UInt64"], ["name", "Nullable(String)"]]

    {:ok, %{rows: [[create_sql]]}} =
      ChDriver.query(
        ddl_conn,
        "SELECT create_table_query FROM system.tables WHERE database = currentDatabase() AND name = 'things_naive'"
      )

    assert create_sql =~ ~r/ORDER BY \(?`?id`?\)?/

    # It really is usable: an explicit id can be inserted and read back
    # (there is nothing *broken* about the column ClickHouse created).
    {:ok, _} =
      ChDriver.query(ddl_conn, "INSERT INTO things_naive (id, name) VALUES (1, 'widget')")

    {:ok, %{rows: rows}} =
      ChDriver.query(ddl_conn, "SELECT id, name FROM things_naive WHERE id = 1")

    assert rows == [[1, "widget"]]

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_naive")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end

  test "the naive pattern's implied 'autoincrement' does NOT exist: omitting :id on insert silently collides on the default value, not a fresh id" do
    ddl_conn = start_ddl_conn!()
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_naive")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
    start_repo!()

    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateThingsNaive}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # Insert two rows the way a Postgres migration would expect to work:
    # leave `id` out entirely and let "the database" generate it.
    {:ok, _} = ChDriver.query(ddl_conn, "INSERT INTO things_naive (name) VALUES ('first')")
    {:ok, _} = ChDriver.query(ddl_conn, "INSERT INTO things_naive (name) VALUES ('second')")

    {:ok, %{rows: rows}} =
      ChDriver.query(ddl_conn, "SELECT id, name FROM things_naive ORDER BY name")

    # Both rows land on id = 0 (UInt64's default) -- ClickHouse has no
    # server-side autoincrement to fall back on, and this adapter doesn't
    # synthesize one either. Both rows are accepted (no uniqueness
    # enforcement raises), but the "primary key" no longer distinguishes
    # them -- exactly the footgun this test documents.
    assert rows == [[0, "first"], [0, "second"]]

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_naive")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end

  test "the documented correct pattern (primary_key: false + explicit ORDER BY/ENGINE, app-supplied id) round-trips correctly and distinguishes rows" do
    ddl_conn = start_ddl_conn!()
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_correct")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
    start_repo!()

    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateThingsCorrect}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    id1 = Ecto.UUID.generate()
    id2 = Ecto.UUID.generate()

    TestRepo.insert!(%ThingCorrect{id: id1, name: "first"})
    TestRepo.insert!(%ThingCorrect{id: id2, name: "second"})

    import Ecto.Query

    rows =
      TestRepo.all(from(t in ThingCorrect, order_by: t.name, select: {t.id, t.name}))

    assert rows == [{id1, "first"}, {id2, "second"}]
    assert id1 != id2

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS things_correct")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end
end
