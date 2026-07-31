defmodule Ecto.Adapters.ClickHouse.StorageMigrationTest do
  @moduledoc """
  End-to-end integration test against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`): `Ecto.Adapter.Storage`
  (`storage_up/1`/`storage_down/1`/`storage_status/1`) and a real
  `Ecto.Migration` actually creating a table via `Ecto.Migrator.run/4`
  against a real server, not just unit-testing DDL string generation.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @base_opts [hostname: "localhost", port: 9000, username: "default", password: ""]

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateWidgets do
    use Ecto.Migration

    def change do
      create table(:widgets, primary_key: false, options: "ENGINE = MergeTree ORDER BY id") do
        add(:id, :id, primary_key: true)
        add(:name, :string, null: false)
        add(:count, :integer, null: false)
      end
    end
  end

  test "storage_up/storage_down/storage_status round-trip against a live ClickHouse server" do
    database = "ecto_storage_test_#{System.unique_integer([:positive])}"
    opts = Keyword.put(@base_opts, :database, database)

    # Not created yet.
    assert :down = Ecto.Adapters.ClickHouse.storage_status(opts)

    # Create it for the first time.
    assert :ok = Ecto.Adapters.ClickHouse.storage_up(opts)
    assert :up = Ecto.Adapters.ClickHouse.storage_status(opts)

    # Creating it again reports :already_up, doesn't error.
    assert {:error, :already_up} = Ecto.Adapters.ClickHouse.storage_up(opts)

    # Drop it.
    assert :ok = Ecto.Adapters.ClickHouse.storage_down(opts)
    assert :down = Ecto.Adapters.ClickHouse.storage_status(opts)

    # Dropping again reports :already_down, doesn't error.
    assert {:error, :already_down} = Ecto.Adapters.ClickHouse.storage_down(opts)
  end

  test "a real Ecto.Migration creates a table and records it in schema_migrations" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS widgets")
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # The table itself was really created.
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = 'widgets'"
      )

    assert rows == [[1]]

    # schema_migrations recorded the version we just ran.
    {:ok, %{rows: version_rows}} =
      ChDriver.query(ddl_conn, "SELECT version FROM schema_migrations WHERE version = #{version}")

    assert version_rows == [[version]]

    # And the created table is actually usable via plain Ecto.
    {:ok, _} =
      ChDriver.query(ddl_conn, "INSERT INTO widgets (id, name, count) VALUES (1, 'gizmo', 3)")

    {:ok, %{rows: widget_rows}} = ChDriver.query(ddl_conn, "SELECT id, name, count FROM widgets")
    assert widget_rows == [[1, "gizmo", 3]]

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS widgets")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end

  test "a change/0 migration's create table is fully reversible via Ecto.Migrator :down" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS widgets")
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

    version = System.unique_integer([:positive, :monotonic])

    # Up: create the table via change/0's auto-inferred forward direction.
    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    {:ok, %{rows: up_table_rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = 'widgets'"
      )

    assert up_table_rows == [[1]]

    {:ok, %{rows: up_version_rows}} =
      ChDriver.query(ddl_conn, "SELECT version FROM schema_migrations WHERE version = #{version}")

    assert up_version_rows == [[version]]

    # Down: change/0 auto-reverses `create table(...)` to `drop table(...)`.
    # This exercises Ecto.Migration.SchemaMigration.down/4, which issues
    # `Repo.delete_all/2` against schema_migrations -- the operation that
    # Connection.delete_all/1 now supports via a synchronous
    # `ALTER TABLE ... DELETE ... SETTINGS mutations_sync = 1` mutation.
    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # The table was actually dropped.
    {:ok, %{rows: down_table_rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = 'widgets'"
      )

    assert down_table_rows == []

    # The schema_migrations bookkeeping row was actually removed (not just
    # marked deleted asynchronously -- mutations_sync=1 makes this visible
    # immediately in a plain SELECT with no polling/retry needed).
    {:ok, %{rows: down_version_rows}} =
      ChDriver.query(ddl_conn, "SELECT version FROM schema_migrations WHERE version = #{version}")

    assert down_version_rows == []

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS widgets")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end
end
