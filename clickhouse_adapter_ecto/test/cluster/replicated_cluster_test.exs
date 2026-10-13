defmodule Ecto.Adapters.ClickHouse.ReplicatedClusterTest do
  @moduledoc """
  Storage and migrations against two replicas sharing a Keeper. Requires
  `docker compose -f docker-compose.cluster.yml up -d --wait`, then
  `mix test --only cluster`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.ClickHouse.TestSupport.Ports

  @moduletag :cluster

  @replica1 [
    hostname: "localhost",
    port: Ports.cluster_replica(1),
    username: "default",
    password: ""
  ]
  @replica2 [
    hostname: "localhost",
    port: Ports.cluster_replica(2),
    username: "default",
    password: ""
  ]

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

  # A migration whose down/0 runs no DDL, so a rollback's only cluster-wide
  # work is delete_all on schema_migrations.
  defmodule NoDdl do
    use Ecto.Migration

    def change, do: execute("SELECT 1", "SELECT 1")
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

    {:ok, _pid} =
      TestRepo.start_link(
        Keyword.merge(@replica1,
          database: database,
          pool_size: 2,
          default_table_engine: "ReplicatedMergeTree"
        )
      )

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

  test "storage_up creates the database on replicas an earlier, partial run missed",
       %{database: database, opts: opts, replica1: replica1, replica2: replica2} do
    # A leftover on the replica storage_up connects to. Plain, because a
    # Replicated database outside ON CLUSTER needs explicit Keeper arguments.
    {:ok, _} = ChDriver.query(replica1, "CREATE DATABASE #{database}")

    assert {:error, :already_up} = Ecto.Adapters.ClickHouse.storage_up(opts)
    assert database_engine(replica2, database) == [["Replicated"]]
  end

  test "storage_up succeeds when only another replica has the database",
       %{database: database, opts: opts, replica1: replica1, replica2: replica2} do
    {:ok, _} = ChDriver.query(replica2, "CREATE DATABASE #{database}")

    assert :ok = Ecto.Adapters.ClickHouse.storage_up(opts)
    assert database_engine(replica1, database) == [["Replicated"]]
  end

  test "storage_down reports :already_down once no replica has the database",
       %{opts: opts} do
    assert {:error, :already_down} = Ecto.Adapters.ClickHouse.storage_down(opts)
  end

  @tag timeout: 120_000
  test "with a replica down, delete_all succeeds and storage DDL fails within the configured timeout",
       %{database: database, opts: opts, replica1: replica1} do
    assert :ok = Ecto.Adapters.ClickHouse.storage_up(opts)

    {:ok, _pid} =
      TestRepo.start_link(
        Keyword.merge(@replica1,
          database: database,
          pool_size: 2,
          default_table_engine: "ReplicatedMergeTree"
        )
      )

    version = System.unique_integer([:positive, :monotonic])
    migrate = &Ecto.Migrator.run(TestRepo, [{version, NoDdl}], &1, all: true, log: false)
    assert [^version] = migrate.(:up)

    on_exit(&start_replica2/0)
    stop_replica2()

    # The delete a rollback issues for schema_migrations. Going through
    # Ecto.Migrator isn't possible here: it first runs CREATE TABLE IF NOT
    # EXISTS schema_migrations, which in a Replicated database waits for
    # every replica too. The mutation can't finish on the stopped replica;
    # the row is gone from the live one and the call must not fail.
    assert {0, []} =
             TestRepo.delete_all(
               from(m in "schema_migrations", where: m.version == type(^version, :integer))
             )

    assert migrated_versions(replica1, database) == []

    opts = Keyword.put(opts, :cluster_ddl_timeout, 2_000)
    {elapsed_us, result} = :timer.tc(fn -> Ecto.Adapters.ClickHouse.storage_down(opts) end)

    assert {:error, message} = result
    assert message =~ "is not finished on 1 of 2 hosts"
    assert elapsed_us < 15_000_000
    assert database_engine(replica1, database) == []

    # The stopped replica runs the queued drop once it is back.
    start_replica2()
    {:ok, replica2} = ChDriver.start_link(@replica2)
    assert eventually(fn -> database_engine(replica2, database) == [] end)
  end

  defp stop_replica2, do: compose!(["stop", "clickhouse2"])
  defp start_replica2, do: compose!(["up", "-d", "--wait", "clickhouse2"])

  defp compose!(args) do
    {output, 0} =
      System.cmd("docker", ["compose", "-f", "docker-compose.cluster.yml" | args],
        stderr_to_stdout: true
      )

    output
  end

  defp eventually(fun, attempts \\ 60) do
    Enum.any?(1..attempts, fn _ -> fun.() || (Process.sleep(500) && false) end)
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
