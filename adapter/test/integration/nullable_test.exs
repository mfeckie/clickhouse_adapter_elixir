defmodule Ecto.Adapters.ClickHouse.NullableIntegrationTest do
  @moduledoc """
  End-to-end integration coverage for `Nullable(T)` column support
  against a *live* ClickHouse instance
  (see `adapter/docker-compose.yml`):

    * DDL generation honors `null: true`/`null: false` (Ecto's own default
      is `null: true`) by emitting `Nullable(...)` or a bare type,
      matching the real `CREATE TABLE` ClickHouse ends up with.
    * a real `Ecto.Migration` with a nullable field round-trips a `nil`
      value through `Repo.insert!/1` and `Repo.all/1`.

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
      create table(:nullable_widgets,
               primary_key: false,
               options: "ENGINE = MergeTree ORDER BY id"
             ) do
        add(:id, :id, primary_key: true)
        add(:name, :string, null: false)
        # No explicit `:null` option -- Ecto's own default is `null: true`,
        # which should now produce `Nullable(Int32)`.
        add(:score, :integer)
      end
    end
  end

  defmodule Widget do
    use Ecto.Schema

    @primary_key false
    schema "nullable_widgets" do
      field(:id, :integer)
      field(:name, :string)
      field(:score, :integer)
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
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS nullable_widgets")
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    # Run the migration once here (rather than in a test) so both tests
    # below can rely on `nullable_widgets` already existing, regardless of
    # which order ExUnit happens to run them in.
    version = System.unique_integer([:positive, :monotonic])

    [^version] =
      Ecto.Migrator.run(TestRepo, [{version, CreateWidgets}], :up,
        all: true,
        log: false,
        log_migrator_sql: false
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS nullable_widgets")
      ChDriver.query(conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn}
  end

  setup %{ddl_conn: ddl_conn} do
    {:ok, _} = ChDriver.query(ddl_conn, "TRUNCATE TABLE nullable_widgets")
    :ok
  end

  test "a migration column with no :null option (Ecto's null: true default) generates a Nullable(...) column, and null: false generates a bare type",
       %{ddl_conn: ddl_conn} do
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns " <>
          "WHERE database = currentDatabase() AND table = 'nullable_widgets' " <>
          "ORDER BY name"
      )

    assert rows == [
             ["id", "UInt64"],
             ["name", "String"],
             ["score", "Nullable(Int32)"]
           ]
  end

  test "a nullable field round-trips nil through Repo.insert!/1 and Repo.all/1" do
    TestRepo.insert!(%Widget{id: 1, name: "with score", score: 42})
    TestRepo.insert!(%Widget{id: 2, name: "no score", score: nil})

    import Ecto.Query

    results = Widget |> order_by([w], asc: w.id) |> TestRepo.all()

    assert [
             %Widget{id: 1, name: "with score", score: 42},
             %Widget{id: 2, name: "no score", score: nil}
           ] = results
  end
end
