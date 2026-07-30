defmodule Ecto.Adapters.ClickHouse.ExtendedTypesIntegrationTest do
  @moduledoc """
  End-to-end integration coverage for the extended native type support added
  in clickhouse_adapter_elixir-8a2.19 (`Array(T)`, `Decimal(P, S)`, `UUID`,
  and `LowCardinality(T)`), against a *live* ClickHouse instance (see
  `adapter/docker-compose.yml`):

    * `{:array, inner_type}` in a migration generates `Array(...)` DDL, and
      an `:array` Ecto schema field round-trips through `Repo.insert!/1` /
      `Repo.all/1`.
    * `:decimal` (already wired for DDL/literal-encoding before this issue)
      round-trips a real `Decimal.t()` end-to-end through the adapter.
    * `:uuid` in a migration generates `UUID` DDL, and a plain `:string`
      Ecto schema field (ClickHouse's `UUID` decodes to the standard
      hyphenated text form, so no dedicated Ecto UUID type is needed --
      see `ChDriver.Protocol.NativeBlock.decode_uuid/1`) round-trips a UUID
      literal.
    * `LowCardinality(T)` is transparent to callers with no dedicated Ecto
      migration type of its own -- a raw ClickHouse type given verbatim as
      a quoted atom in the migration
      (`add(:status, :"LowCardinality(String)")` -- `Ecto.Migration.add/3`
      itself rejects a plain string here, confirmed live) plus a plain
      `:string` schema field round-trips exactly like a bare `String`
      column would.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateWidgets do
    use Ecto.Migration

    def change do
      create table(:extended_type_widgets,
               primary_key: false,
               options: "ENGINE = MergeTree ORDER BY id"
             ) do
        add(:id, :id, primary_key: true)
        add(:tags, {:array, :string}, null: false)
        add(:scores, {:array, :integer}, null: false)
        add(:amount, :decimal, null: false)
        add(:external_id, :uuid, null: false)
        add(:status, :"LowCardinality(String)", null: false)
      end
    end
  end

  defmodule Widget do
    use Ecto.Schema

    @primary_key false
    schema "extended_type_widgets" do
      field(:id, :integer)
      field(:tags, {:array, :string})
      field(:scores, {:array, :integer})
      field(:amount, :decimal)
      field(:external_id, :string)
      field(:status, :string)
    end
  end

  setup_all do
    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 5
      )

    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS extended_type_widgets")
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    version = System.unique_integer([:positive, :monotonic])

    [^version] =
      Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :up,
        all: true,
        log: false,
        log_migrator_sql: false
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS extended_type_widgets")
      ChDriver.query(conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn}
  end

  setup %{ddl_conn: ddl_conn} do
    {:ok, _} = ChDriver.query(ddl_conn, "TRUNCATE TABLE extended_type_widgets")
    :ok
  end

  test "the migration generates the expected ClickHouse column types", %{ddl_conn: ddl_conn} do
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns " <>
          "WHERE database = currentDatabase() AND table = 'extended_type_widgets' " <>
          "ORDER BY name"
      )

    assert rows == [
             ["amount", "Decimal(38, 9)"],
             ["external_id", "UUID"],
             ["id", "UInt64"],
             ["scores", "Array(Int32)"],
             ["status", "LowCardinality(String)"],
             ["tags", "Array(String)"]
           ]
  end

  test "Array(T), Decimal, UUID, and LowCardinality(String) fields all round-trip through Repo.insert!/1 and Repo.all/1" do
    TestRepo.insert!(%Widget{
      id: 1,
      tags: ["red", "blue"],
      scores: [10, 20, 30],
      amount: Decimal.new("1234.567800000"),
      external_id: "61f0c404-5cb3-11e7-907b-a6006ad3dba0",
      status: "active"
    })

    TestRepo.insert!(%Widget{
      id: 2,
      tags: [],
      scores: [],
      amount: Decimal.new("0.000000000"),
      external_id: "00000000-0000-0000-0000-000000000000",
      status: "active"
    })

    import Ecto.Query

    results = Widget |> order_by([w], asc: w.id) |> TestRepo.all()

    assert [
             %Widget{
               id: 1,
               tags: ["red", "blue"],
               scores: [10, 20, 30],
               amount: amount1,
               external_id: "61f0c404-5cb3-11e7-907b-a6006ad3dba0",
               status: "active"
             },
             %Widget{
               id: 2,
               tags: [],
               scores: [],
               amount: amount2,
               external_id: "00000000-0000-0000-0000-000000000000",
               status: "active"
             }
           ] = results

    assert Decimal.equal?(amount1, Decimal.new("1234.567800000"))
    assert Decimal.equal?(amount2, Decimal.new("0"))
  end
end
