defmodule Ecto.Adapters.ClickHouse.FinalIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for `lock: "FINAL"` (see
  `Ecto.Adapters.ClickHouse.Expression.from/2`).

  `lock: "FINAL"` is the per-query alternative to setting the `final`
  connection-level server setting: it appends ClickHouse's `FINAL`
  modifier only to the query it's used on, rather than to every query on
  the connection (including tables, like an already-deduplicated
  aggregating view, that don't need it and would pay real merge-time
  overhead for no benefit).

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to
  have been run first.
  """

  use ExUnit.Case, async: false
  import Ecto.Adapters.ClickHouse.TestCase

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Widget do
    use Ecto.Schema

    @primary_key false
    schema "final_widgets" do
      field(:id, :integer)
      field(:name, :string)
    end
  end

  setup_clickhouse_tables(TestRepo,
    final_widgets:
      "CREATE TABLE final_widgets (id UInt64, name String) " <>
        "ENGINE = ReplacingMergeTree ORDER BY id"
  )

  defp seed_duplicate_versions do
    # Same primary key (`id`) inserted twice with different `name`s --
    # `ReplacingMergeTree` only collapses these at merge time (or query
    # time, with `FINAL`), so without `FINAL` both rows are still visible.
    TestRepo.insert!(%Widget{id: 1, name: "v1"})
    TestRepo.insert!(%Widget{id: 1, name: "v2"})
  end

  test "without lock: \"FINAL\", both un-merged ReplacingMergeTree versions are returned" do
    seed_duplicate_versions()

    import Ecto.Query

    query = from(w in Widget, where: w.id == 1, select: w.name)

    assert Enum.sort(TestRepo.all(query)) == ["v1", "v2"]
  end

  test "lock: \"FINAL\" collapses ReplacingMergeTree versions down to the latest at query time" do
    seed_duplicate_versions()

    import Ecto.Query

    query = from(w in Widget, where: w.id == 1, select: w.name, lock: "FINAL")

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ ~r/FROM "final_widgets" AS \w+ FINAL/

    assert TestRepo.all(query) == ["v2"]
  end

  test "any lock: value other than \"FINAL\" raises Ecto.QueryError instead of being silently dropped" do
    import Ecto.Query

    query = from(w in Widget, lock: "FOR UPDATE")

    assert_raise Ecto.QueryError, ~r/only supports `lock: "FINAL"`/, fn ->
      Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    end
  end
end
