defmodule Ecto.Adapters.ClickHouse.AliasColumnTest do
  @moduledoc """
  End-to-end coverage that the migration DSL's `:alias` column option
  (see `Ecto.Adapters.ClickHouse.DDL`'s moduledoc) produces a working
  ClickHouse `ALIAS` column against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`) -- not just that the
  `CREATE TABLE` succeeds.

  This recreates roster's real `assignments.status` computed column: an
  `Enum8` (built via `Ecto.Adapters.ClickHouse.Migration.enum8/1`) whose
  value is computed on read from other columns (`expired_at`, `end_at`,
  `start_at`) via a `multiIf(...)` expression, rather than stored.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to
  have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.ClickHouse.Migration

  @table "adapter_alias_assignments"

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  # Mirrors roster's real assignments.status column:
  #
  #     Enum8('pending' = 0, 'active' = 1, 'expired' = 2) ALIAS multiIf(
  #       (isNotNull(expired_at) AND (expired_at < now64(3))) OR (end_at < now64(3)), 'expired',
  #       start_at > now64(3), 'pending',
  #       'active'
  #     )
  defmodule CreateAssignments do
    use Ecto.Migration

    def change do
      create table(:adapter_alias_assignments, primary_key: false, options: "ENGINE = Memory") do
        add(:id, :id, primary_key: true)
        add(:expired_at, :utc_datetime, null: true)
        add(:end_at, :utc_datetime, null: false)
        add(:start_at, :utc_datetime, null: false)

        add(
          :status,
          Migration.enum8(pending: 0, active: 1, expired: 2),
          alias: """
          multiIf(
            (isNotNull(expired_at) AND (expired_at < now64(3))) OR (end_at < now64(3)), 'expired',
            start_at > now64(3), 'pending',
            'active'
          )
          """
        )
      end
    end
  end

  test "an ALIAS status column computes pending/active/expired from other columns on read" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS #{@table}")
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
             Ecto.Migrator.run(TestRepo, [{version, CreateAssignments}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # Confirm the column really was created as ALIAS, not a stored/Nullable
    # column -- `system.columns.default_kind` is `'ALIAS'` for an ALIAS
    # column and empty for a plain stored column.
    {:ok, %{rows: [[type, default_kind]]}} =
      ChDriver.query(
        ddl_conn,
        "SELECT type, default_kind FROM system.columns WHERE database = currentDatabase() " <>
          "AND table = ? AND name = 'status'",
        [@table]
      )

    assert type == "Enum8('pending' = 0, 'active' = 1, 'expired' = 2)"
    assert default_kind == "ALIAS"

    # id=1 pending: starts in the future, not expired.
    # id=2 active: already started, ends in the future, not expired.
    # id=3 expired (via expired_at): explicitly marked expired in the past.
    # id=4 expired (via end_at only, expired_at NULL): ended in the past.
    {:ok, _} =
      ChDriver.query(ddl_conn, """
      INSERT INTO #{@table} (id, expired_at, end_at, start_at) VALUES
      (1, NULL, now() + INTERVAL 2 DAY, now() + INTERVAL 1 DAY),
      (2, NULL, now() + INTERVAL 1 DAY, now() - INTERVAL 1 DAY),
      (3, now() - INTERVAL 1 HOUR, now() + INTERVAL 1 DAY, now() - INTERVAL 2 DAY),
      (4, NULL, now() - INTERVAL 1 HOUR, now() - INTERVAL 2 DAY)
      """)

    {:ok, %{rows: rows}} =
      ChDriver.query(ddl_conn, "SELECT id, status FROM #{@table} ORDER BY id")

    # ch_driver decodes Enum8 to its underlying integer value, not the
    # string label (matching migration_builders_test.exs's convention).
    assert rows == [
             [1, 0],
             [2, 1],
             [3, 2],
             [4, 2]
           ]

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS #{@table}")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end
end
