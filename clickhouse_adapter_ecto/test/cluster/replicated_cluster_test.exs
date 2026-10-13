defmodule Ecto.Adapters.ClickHouse.ReplicatedClusterTest do
  @moduledoc """
  Storage and migrations against two replicas sharing a Keeper. Requires
  `docker compose -f docker-compose.cluster.yml up -d --wait`, then
  `mix test --only cluster`.
  """

  use ExUnit.Case, async: false

  @moduletag :cluster

  @replica1 [hostname: "localhost", port: 19000, username: "default", password: ""]
  @replica2 [hostname: "localhost", port: 19001, username: "default", password: ""]

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateWidgets do
    use Ecto.Migration

    def change do
      create table(:widgets,
               primary_key: false,
               options: "ENGINE = ReplicatedMergeTree ORDER BY id"
             ) do
        add(:id, :id, primary_key: true)
        add(:name, :string, null: false)
      end
    end
  end

  setup do
    database = "ecto_cluster_test_#{System.unique_integer([:positive])}"

    opts =
      @replica1
      |> Keyword.put(:database, database)
      |> Keyword.put(:database_engine, "Replicated")
      |> Keyword.put(:cluster, "{cluster}")

    {:ok, replica1} = ChDriver.start_link(@replica1)
    {:ok, replica2} = ChDriver.start_link(@replica2)

    on_exit(fn -> Ecto.Adapters.ClickHouse.storage_down(opts) end)

    %{database: database, opts: opts, replica1: replica1, replica2: replica2}
  end

  test "storage_up creates a Replicated database on every replica, storage_down drops it",
       %{database: database, opts: opts, replica1: replica1, replica2: replica2} do
    assert :ok = Ecto.Adapters.ClickHouse.storage_up(opts)

    for conn <- [replica1, replica2] do
      assert database_engine(conn, database) == [["Replicated"]]
    end

    assert :ok = Ecto.Adapters.ClickHouse.storage_down(opts)

    for conn <- [replica1, replica2] do
      assert database_engine(conn, database) == []
    end
  end

  test "migrations replicate, and a rollback is visible on the other replica straight away",
       %{database: database, opts: opts, replica2: replica2} do
    assert :ok = Ecto.Adapters.ClickHouse.storage_up(opts)

    # The adapter reads it via repo.config(), which only sees app env.
    Application.put_env(:clickhouse_adapter_ecto, TestRepo,
      default_table_engine: "ReplicatedMergeTree"
    )

    on_exit(fn -> Application.delete_env(:clickhouse_adapter_ecto, TestRepo) end)

    {:ok, _pid} =
      TestRepo.start_link(Keyword.merge(@replica1, database: database, pool_size: 2))

    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    {:ok, _} = ChDriver.query(replica2, "SYSTEM SYNC DATABASE REPLICA #{database}")
    {:ok, _} = ChDriver.query(replica2, "SYSTEM SYNC REPLICA #{database}.schema_migrations")

    # schema_migrations picks up the repo's default_table_engine.
    {:ok, %{rows: engines}} =
      ChDriver.query(
        replica2,
        "SELECT name, engine FROM system.tables WHERE database = '#{database}' ORDER BY name"
      )

    assert engines == [
             ["schema_migrations", "ReplicatedMergeTree"],
             ["widgets", "ReplicatedMergeTree"]
           ]

    assert migrated_versions(replica2, database) == [[version]]

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    # No SYNC REPLICA here. delete_all's mutations_sync = 2 has already
    # waited for every replica.
    assert migrated_versions(replica2, database) == []
  end

  defp database_engine(conn, database) do
    {:ok, %{rows: rows}} =
      ChDriver.query(conn, "SELECT engine FROM system.databases WHERE name = '#{database}'")

    rows
  end

  defp migrated_versions(conn, database) do
    {:ok, %{rows: rows}} =
      ChDriver.query(conn, "SELECT version FROM #{database}.schema_migrations")

    rows
  end
end
