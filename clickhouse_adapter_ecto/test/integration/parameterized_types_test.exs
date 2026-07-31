defmodule Ecto.Adapters.ClickHouse.ParameterizedTypesTest do
  @moduledoc """
  End-to-end integration coverage for `Ecto.Adapters.ClickHouse.Types.FixedString`
  and `Ecto.Adapters.ClickHouse.Migration`, against a *live* ClickHouse
  instance (see `clickhouse_adapter_ecto/docker-compose.yml`):

    * `Ecto.Adapters.ClickHouse.Migration.fixed_string/1` generates
      `FixedString(N)` DDL via `add/3`'s type-safe (validated) syntax,
      matching `system.columns`.
    * `Ecto.Adapters.ClickHouse.Migration.low_cardinality/1` generates
      `LowCardinality(T)` DDL the same way.
    * `Ecto.Adapters.ClickHouse.Types.FixedString` round-trips a schema
      field through `Repo.insert!/1` and `Repo.all/1`, including
      ClickHouse's own zero-padding of a shorter value.
    * `Ecto.Adapters.ClickHouse.Types.FixedString.cast/2` rejects a value
      longer than `size` before it ever reaches ClickHouse.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.ClickHouse.Migration, as: ChMigration
  alias Ecto.Adapters.ClickHouse.Types.FixedString

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateWidgets do
    use Ecto.Migration

    def change do
      create table(:parameterized_type_widgets,
               primary_key: false,
               options: "ENGINE = MergeTree ORDER BY id"
             ) do
        add(:id, :id, primary_key: true)
        add(:code, ChMigration.fixed_string(8), null: false)
        add(:status, ChMigration.low_cardinality(:string), null: false)
      end
    end
  end

  defmodule Widget do
    use Ecto.Schema

    @primary_key false
    schema "parameterized_type_widgets" do
      field(:id, :integer)
      field(:code, FixedString, size: 8)
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
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS parameterized_type_widgets")
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
      ChDriver.query(conn, "DROP TABLE IF EXISTS parameterized_type_widgets")
      ChDriver.query(conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn}
  end

  setup %{ddl_conn: ddl_conn} do
    {:ok, _} = ChDriver.query(ddl_conn, "TRUNCATE TABLE parameterized_type_widgets")
    :ok
  end

  test "the migration generates FixedString(8) and LowCardinality(String) column types", %{
    ddl_conn: ddl_conn
  } do
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns " <>
          "WHERE database = currentDatabase() AND table = 'parameterized_type_widgets' " <>
          "ORDER BY name"
      )

    assert rows == [
             ["code", "FixedString(8)"],
             ["id", "UInt64"],
             ["status", "LowCardinality(String)"]
           ]
  end

  test "a FixedString(8) schema field round-trips through Repo.insert!/1 and Repo.all/1, zero-padded by ClickHouse" do
    TestRepo.insert!(%Widget{id: 1, code: "ab", status: "active"})
    TestRepo.insert!(%Widget{id: 2, code: "abcdefgh", status: "inactive"})

    import Ecto.Query

    results = Widget |> order_by([w], asc: w.id) |> TestRepo.all()

    assert [
             %Widget{id: 1, code: <<"ab", 0, 0, 0, 0, 0, 0>>, status: "active"},
             %Widget{id: 2, code: "abcdefgh", status: "inactive"}
           ] = results
  end

  test "FixedString.cast/2 rejects a value longer than size before it reaches ClickHouse" do
    code_type = Ecto.ParameterizedType.init(FixedString, size: 8)

    changeset =
      {%Widget{}, %{code: code_type, status: :string}}
      |> Ecto.Changeset.cast(%{code: "waytoolongforsize8", status: "x"}, [:code, :status])

    refute changeset.valid?
    assert %{code: ["should be at most 8 byte(s) to fit FixedString(8)"]} = errors_on(changeset)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
