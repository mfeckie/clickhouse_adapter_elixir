defmodule Ecto.Adapters.ClickHouse.TupleLowCardinalityNullableTest do
  @moduledoc """
  End-to-end coverage that `Tuple(...)` and `LowCardinality(Nullable(T))`
  columns are selectable through the adapter, against a *live* ClickHouse
  instance (see `clickhouse_adapter_ecto/docker-compose.yml`).

  Both used to drop the connection at the driver layer, so these are the
  adapter-level counterparts to `ch_driver`'s own coverage: one path through
  `Repo.query/2` (raw SQL, returning driver-decoded values as-is) and one
  through a schema field and `Repo.all/1`.

  Neither type has an `Ecto.Migration` helper, so the table is created with
  raw DDL -- the same thing `Ecto.Adapters.ClickHouse.DDL` tells you to do
  via `execute/1` for types it can't map.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @table "adapter_tuple_lcn"

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Row do
    use Ecto.Schema

    @primary_key false
    schema "adapter_tuple_lcn" do
      field(:id, :integer)
      field(:s, :string)
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

    TestRepo.query!("DROP TABLE IF EXISTS #{@table}")

    TestRepo.query!("""
    CREATE TABLE #{@table} (
      id UInt32,
      s LowCardinality(Nullable(String)),
      t Tuple(Int32, String)
    ) ENGINE = Memory
    """)

    TestRepo.query!(
      "INSERT INTO #{@table} VALUES (1, 'a', (1, 'x')), (2, NULL, (2, 'y')), (3, '', (3, 'z'))"
    )

    # Drop via a plain driver connection rather than the repo: an on_exit
    # callback can outlive the repo's supervised pool, and checking a
    # connection out of a shutting-down pool exits.
    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS #{@table}")
    end)

    :ok
  end

  test "Repo.query/2 returns decoded tuples and distinguishes '' from NULL" do
    assert %{rows: rows} =
             TestRepo.query!("SELECT id, s, t FROM #{@table} ORDER BY id")

    assert rows == [
             [1, "a", {1, "x"}],
             [2, nil, {2, "y"}],
             [3, "", {3, "z"}]
           ]
  end

  test "a LowCardinality(Nullable(String)) column loads through a schema field" do
    import Ecto.Query

    rows = TestRepo.all(from(r in Row, select: {r.id, r.s}, order_by: r.id))

    # The empty string at id 3 must not come back as nil: inside a
    # LowCardinality dictionary, NULL is the index-0 sentinel and a real ""
    # keeps its own slot.
    assert rows == [{1, "a"}, {2, nil}, {3, ""}]
  end
end
