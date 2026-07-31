defmodule Ecto.Adapters.ClickHouse.DataSkippingIndexTest do
  @moduledoc """
  End-to-end integration test against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`) proving that a data-skipping index
  (`ALTER TABLE ... ADD INDEX ... TYPE minmax ...`), added via a raw
  `execute/1` statement in an `Ecto.Migration`, is actually created on the
  server and actually consulted by the query planner -- not just that the
  DDL string is well-formed.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule AddAmountMinmaxIndex do
    use Ecto.Migration

    def up do
      execute("ALTER TABLE metrics ADD INDEX amount_minmax_idx amount TYPE minmax GRANULARITY 4")

      execute("ALTER TABLE metrics MATERIALIZE INDEX amount_minmax_idx")
    end

    def down do
      execute("ALTER TABLE metrics DROP INDEX amount_minmax_idx")
    end
  end

  setup do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS metrics")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "CREATE TABLE metrics (id UInt64, amount Int32) ENGINE = MergeTree ORDER BY id"
      )

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "INSERT INTO metrics SELECT number, number * 3 FROM numbers(200000)"
      )

    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

    on_exit(fn ->
      {:ok, cleanup_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(cleanup_conn, "DROP TABLE IF EXISTS metrics")
      ChDriver.query(cleanup_conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn}
  end

  test "a raw execute/1 migration adds a minmax data-skipping index that ClickHouse records and the planner uses",
       %{ddl_conn: ddl_conn} do
    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, AddAmountMinmaxIndex}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    assert {:ok, %{rows: index_rows}} =
             ChDriver.query(
               ddl_conn,
               "SELECT name, type, type_full, expr, granularity FROM system.data_skipping_indices " <>
                 "WHERE table = 'metrics' AND name = 'amount_minmax_idx'"
             )

    assert [["amount_minmax_idx", "minmax", "minmax", "amount", 4]] = index_rows

    assert {:ok, %{rows: explain_rows}} =
             ChDriver.query(
               ddl_conn,
               "EXPLAIN indexes = 1 SELECT count() FROM metrics WHERE amount > 500000"
             )

    explain_text = explain_rows |> Enum.map(&hd/1) |> Enum.join("\n")

    assert explain_text =~ "amount_minmax_idx"
    assert explain_text =~ "minmax GRANULARITY 4"

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, AddAmountMinmaxIndex}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    assert {:ok, %{rows: []}} =
             ChDriver.query(
               ddl_conn,
               "SELECT name FROM system.data_skipping_indices " <>
                 "WHERE table = 'metrics' AND name = 'amount_minmax_idx'"
             )
  end
end
