defmodule Ecto.Adapters.ClickHouse.RepoIntegrationTest do
  @moduledoc """
  End-to-end integration test against a *live* ClickHouse instance (see
  `clickhouse_adapter_ecto/docker-compose.yml`): `Ecto.Repo.insert!/1` and
  `Ecto.Repo.all/1` actually round-tripping data through
  `Ecto.Adapters.ClickHouse` (an `Ecto.Adapters.SQL`-based adapter over
  `Ecto.Adapters.ClickHouse.Connection`) against a real server, not just
  unit-testing SQL string generation.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first;
  see the moduledoc there for details.
  """

  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Event do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:id, :integer)
      field(:name, :string)
      field(:count, :integer)
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
        pool_size: 2
      )

    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)

    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS events")

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "CREATE TABLE events (id UInt64, name String, count Int32) ENGINE = Memory"
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS events")
    end)

    :ok
  end

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(conn, "TRUNCATE TABLE events")
    :ok
  end

  test "Repo.insert! and Repo.all/1 round-trip against a live ClickHouse server" do
    inserted = TestRepo.insert!(%Event{id: 1, name: "signup", count: 42})

    assert %Event{id: 1, name: "signup", count: 42} = inserted

    assert [%Event{id: 1, name: "signup", count: 42}] = TestRepo.all(Event)
  end

  test "Repo.insert! + Repo.all/1 with a WHERE/ORDER BY/LIMIT filtered query" do
    TestRepo.insert!(%Event{id: 10, name: "login", count: 1})
    TestRepo.insert!(%Event{id: 11, name: "logout", count: 2})
    TestRepo.insert!(%Event{id: 12, name: "login", count: 3})

    import Ecto.Query

    results =
      Event
      |> where([e], e.name == "login")
      |> order_by([e], desc: e.count)
      |> limit(2)
      |> TestRepo.all()

    assert [%Event{id: 12, count: 3}, %Event{id: 10, count: 1}] = results
  end

  test "a real ClickHouse error (querying a nonexistent table) surfaces as an exception, not a crash" do
    defmodule NoSuchTable do
      use Ecto.Schema

      @primary_key false
      schema "this_table_does_not_exist" do
        field(:id, :integer)
      end
    end

    TestRepo.insert!(%Event{id: 1, name: "signup", count: 42})

    assert_raise ChDriver.Error, ~r/unknown table/i, fn ->
      TestRepo.all(NoSuchTable)
    end

    # the pool must still be usable afterwards -- a query-level ClickHouse
    # error must not have torn down the underlying connection.
    assert [%Event{id: 1}] = TestRepo.all(Event)
  end
end
