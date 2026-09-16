defmodule Ecto.Adapters.ClickHouse.TableOptionsTtlTest do
  @moduledoc """
  End-to-end integration test against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`): proves that a `:ttl`
  clause built by `Ecto.Adapters.ClickHouse.Migration.table_options/1`
  and run through a real `Ecto.Migration` actually lands in the DDL
  ClickHouse stores for the table -- not just that `table_options/1`
  produces the expected string in isolation.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.ClickHouse.Migration

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateEventsWithTtl do
    use Ecto.Migration

    def change do
      create table(:events_with_ttl,
               primary_key: false,
               options:
                 Migration.table_options(
                   engine: "ReplacingMergeTree(inserted_at)",
                   order_by: "(id)",
                   ttl: "inserted_at + toIntervalYear(2)"
                 )
             ) do
        add(:id, :id, primary_key: true)
        add(:inserted_at, :utc_datetime, null: false)
      end
    end
  end

  test "a table created with a :ttl clause actually stores TTL in its DDL on the live server" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS events_with_ttl")
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
             Ecto.Migrator.run(TestRepo, [{version, CreateEventsWithTtl}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    {:ok, %{rows: [[create_ddl]]}} =
      ChDriver.query(ddl_conn, "SHOW CREATE TABLE events_with_ttl")

    assert create_ddl =~ "TTL inserted_at + toIntervalYear(2)"

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS events_with_ttl")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end
end
