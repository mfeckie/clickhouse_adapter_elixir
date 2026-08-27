defmodule Ecto.Adapters.ClickHouse.CteIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for common table expressions (see
  `Ecto.Adapters.ClickHouse.QueryBuilder.cte/2`).

  `with_cte/3`'s non-recursive form -- both the `^existing_query`
  (`Ecto.Query`) shape and the raw `fragment(...)` shape -- renders onto
  ClickHouse's own `WITH name AS (subquery) SELECT ...` clause, which every
  currently-supported (`26.7`) ClickHouse version accepts.

  `recursive_ctes(query, true)`/`with_cte(..., recursive: true)`, the
  Postgres-only `:materialized` CTE option, and `:operation` values other
  than `:all` all raise a clear `Ecto.QueryError` instead of being silently
  mishandled -- see the comment above
  `Ecto.Adapters.ClickHouse.QueryBuilder.cte/2` for the full rationale.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: false
  import Ecto.Adapters.ClickHouse.TestCase
  import Ecto.Query

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Widget do
    use Ecto.Schema

    @primary_key false
    schema "cte_widgets" do
      field(:id, :integer)
      field(:name, :string)
      field(:price, :integer)
    end
  end

  setup_clickhouse_tables(TestRepo,
    cte_widgets:
      "CREATE TABLE cte_widgets (id UInt64, name String, price UInt64) " <>
        "ENGINE = MergeTree ORDER BY id"
  )

  defp seed_widgets do
    TestRepo.insert!(%Widget{id: 1, name: "cheap", price: 10})
    TestRepo.insert!(%Widget{id: 2, name: "mid", price: 50})
    TestRepo.insert!(%Widget{id: 3, name: "pricey", price: 100})
  end

  test "with_cte/3 with an ^interpolated Ecto.Query renders WITH ... AS (subquery) and is queryable via the CTE name" do
    seed_widgets()

    expensive = from(w in Widget, where: w.price > 40, select: %{id: w.id, name: w.name})

    query =
      Widget
      |> with_cte("expensive", as: ^expensive)
      |> recursive_ctes(false)
      |> join(:inner, [w], e in "expensive", on: e.id == w.id)
      |> select([w, e], e.name)
      |> order_by([w, e], e.name)

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ ~r/^WITH "expensive" AS \(SELECT/

    assert TestRepo.all(query) == ["mid", "pricey"]
  end

  test "with_cte/3 with a fragment CTE body renders the fragment verbatim inside WITH" do
    seed_widgets()

    query =
      Widget
      |> with_cte("max_price", as: fragment("SELECT max(price) AS price FROM cte_widgets"))
      |> join(:cross, [w], m in "max_price")
      |> where([w, m], w.price == m.price)
      |> select([w, m], w.name)

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ ~r/^WITH "max_price" AS \(SELECT max\(price\)/

    assert TestRepo.all(query) == ["pricey"]
  end

  test "recursive_ctes(query, true) raises Ecto.QueryError instead of emitting WITH RECURSIVE" do
    expensive = from(w in Widget, where: w.price > 40)

    query =
      Widget
      |> with_cte("expensive", as: ^expensive)
      |> recursive_ctes(true)
      |> select([w], w.id)

    assert_raise Ecto.QueryError, ~r/does not support recursive CTEs/, fn ->
      Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    end
  end

  test "with_cte(..., materialized: true) raises Ecto.QueryError instead of being silently dropped" do
    expensive = from(w in Widget, where: w.price > 40)

    query =
      Widget
      |> with_cte("expensive", as: ^expensive, materialized: true)
      |> select([w], w.id)

    assert_raise Ecto.QueryError, ~r/does not support the `:materialized` CTE option/, fn ->
      Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    end
  end

  test "with_cte(..., operation: :update_all) raises Ecto.QueryError instead of being silently dropped" do
    expensive = from(w in Widget, where: w.price > 40)

    query =
      Widget
      |> with_cte("expensive", as: ^expensive, operation: :update_all)
      |> select([w], w.id)

    assert_raise Ecto.QueryError, ~r/only supports :all-operation CTEs/, fn ->
      Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    end
  end
end
