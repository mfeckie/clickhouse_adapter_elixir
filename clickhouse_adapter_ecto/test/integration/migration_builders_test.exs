defmodule Ecto.Adapters.ClickHouse.MigrationBuildersTest do
  @moduledoc """
  End-to-end coverage that `Ecto.Adapters.ClickHouse.Migration`'s new
  column-type builders (`enum8/1`, `tuple/1`, `variant/1`,
  `aggregate_function/2`, `simple_aggregate_function/2`) produce columns
  that really create against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`), with the resulting types
  verified via `DESCRIBE TABLE`/`system.columns`, not just that the
  migration doesn't raise.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.ClickHouse.Migration

  @table "adapter_migration_builders"

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateBuilders do
    use Ecto.Migration

    def change do
      create table(:adapter_migration_builders, primary_key: false, options: "ENGINE = Memory") do
        add(:id, :id, primary_key: true)
        add(:status, Migration.enum8(unknown: 0, active: 1, archived: 2), null: false)
        add(:point, Migration.tuple(x: :float, y: :float), null: false)

        add(
          :answers,
          Migration.tuple(
            id: :integer,
            options: {:array, Migration.tuple(label: :string, correct: :boolean)}
          ),
          null: false
        )

        # Variant, AggregateFunction, and SimpleAggregateFunction can't be
        # wrapped in Nullable(...) in ClickHouse, so these must be
        # `null: false` (matching e.g. `status Tuple(...)` columns).
        add(:mixed, Migration.variant([:integer, :string, :date]), null: false)
        add(:visitors, Migration.aggregate_function("uniqExact", :uuid), null: false)
        add(:total, Migration.simple_aggregate_function("sum", :bigint), null: false)
      end
    end
  end

  test "a real Ecto.Migration creates the new builder column types against live ClickHouse" do
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
             Ecto.Migrator.run(TestRepo, [{version, CreateBuilders}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns WHERE database = currentDatabase() AND table = ? ORDER BY position",
        [@table]
      )

    columns = Map.new(rows, fn [name, type] -> {name, type} end)

    assert columns["id"] == "UInt64"
    assert columns["status"] == "Enum8('unknown' = 0, 'active' = 1, 'archived' = 2)"
    assert columns["point"] == "Tuple(x Float64, y Float64)"

    assert columns["answers"] ==
             "Tuple(id Int32, options Array(Tuple(label String, correct UInt8)))"

    # ClickHouse stores Variant's inner types sorted (alphabetically), not
    # necessarily in the order they were given -- confirmed live rather
    # than assumed.
    assert columns["mixed"] == "Variant(Date, Int32, String)"
    assert columns["visitors"] == "AggregateFunction(uniqExact, UUID)"
    assert columns["total"] == "SimpleAggregateFunction(sum, Int64)"

    # And the table is actually usable end-to-end: insert a row exercising
    # every new column type, then confirm (via a driver-agnostic
    # toString()/count query, since the ch_driver NIF doesn't decode every
    # exotic native wire type like SimpleAggregateFunction/AggregateFunction
    # for a plain SELECT) that ClickHouse itself accepted and stored the
    # values as expected.
    {:ok, _} =
      ChDriver.query(ddl_conn, """
      INSERT INTO #{@table} (id, status, point, answers, mixed, visitors, total) VALUES
      (1, 'active', (1.5, 2.5), (1, [('a', true), ('b', false)]), 42,
       initializeAggregation('uniqExactState', toUUID('00000000-0000-0000-0000-000000000001')),
       initializeAggregation('sumSimpleState', 7))
      """)

    {:ok, %{rows: [[status, point_str, answers_str, mixed_str, total]]}} =
      ChDriver.query(
        ddl_conn,
        "SELECT status, toString(point), toString(answers), toString(mixed), toInt64(total) " <>
          "FROM #{@table} WHERE id = 1"
      )

    # ch_driver decodes Enum8 to its underlying integer value, not the
    # string label.
    assert status == 1
    assert point_str == "(1.5,2.5)"
    assert answers_str == "(1,[('a',1),('b',0)])"
    assert mixed_str == "42"
    assert total == 7

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS #{@table}")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")
  end
end
