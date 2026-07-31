defmodule Ecto.Adapters.ClickHouse.GroupByIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for GROUP BY/HAVING support (see
  `Ecto.Adapters.ClickHouse.Expression.group_by/2` and `having/2`, and
  `Ecto.Adapters.ClickHouse.QueryBuilder.all/2`).

  Standard SQL `GROUP BY` on one or more columns/expressions, `HAVING` on the
  aggregated result (rendered through the same `boolean/4` machinery `WHERE`
  already uses), and the standard aggregate functions Ecto's query API
  exposes (`count/0,1,2`, `sum/1`, `avg/1`, `min/1`, `max/1`) are supported --
  these are ordinary function calls that already round-trip through
  `Expression.expr/3` once `GROUP BY` stops being rejected outright, with one
  exception that needed dedicated handling: `count(field, :distinct)` renders
  as `count(DISTINCT field)`.

  Explicitly out of scope, and not exercised here because there is nothing in
  `Ecto.Query`'s public API that reaches these code paths at all: SQL
  `GROUPING SETS`/`ROLLUP`/`CUBE`, ClickHouse's `WITH TOTALS`/`WITH ROLLUP`/
  `WITH CUBE` modifiers, and ClickHouse-specific aggregate functions not in
  Ecto's standard query API (`uniq`, `uniqExact`, `quantile`, etc.) -- see the
  moduledoc-adjacent comments above `Expression.group_by/2` for the full
  rationale. `filter/2` (Postgres-only FILTER-on-aggregate) is also rejected
  with a clear error rather than silently producing invalid SQL -- see
  `Expression.expr/3`'s `{:filter, ...}` clause.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
  """

  use ExUnit.Case, async: false
  import Ecto.Adapters.ClickHouse.TestCase

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key false
    schema "group_by_posts" do
      field(:id, :integer)
      field(:title, :string)
      field(:author, :string)
      field(:views, :integer)

      has_many(:comments, Ecto.Adapters.ClickHouse.GroupByIntegrationTest.Comment,
        foreign_key: :post_id,
        references: :id
      )
    end
  end

  defmodule Comment do
    use Ecto.Schema

    @primary_key false
    schema "group_by_comments" do
      field(:id, :integer)
      field(:post_id, :integer)
      field(:body, :string)

      belongs_to(:post, Ecto.Adapters.ClickHouse.GroupByIntegrationTest.Post,
        foreign_key: :post_id,
        references: :id,
        define_field: false
      )
    end
  end

  setup_clickhouse_tables TestRepo,
    group_by_posts:
      "CREATE TABLE group_by_posts (id UInt64, title String, author String, views UInt64) " <>
        "ENGINE = MergeTree ORDER BY id",
    group_by_comments:
      "CREATE TABLE group_by_comments (id UInt64, post_id UInt64, body String) " <>
        "ENGINE = MergeTree ORDER BY id"

  defp seed do
    TestRepo.insert!(%Post{id: 1, title: "first post", author: "alice", views: 10})
    TestRepo.insert!(%Post{id: 2, title: "second post", author: "alice", views: 20})
    TestRepo.insert!(%Post{id: 3, title: "third post", author: "bob", views: 5})

    TestRepo.insert!(%Comment{id: 100, post_id: 1, body: "nice post"})
    TestRepo.insert!(%Comment{id: 101, post_id: 1, body: "another comment"})
    TestRepo.insert!(%Comment{id: 102, post_id: 2, body: "on second post"})
  end

  test "a basic GROUP BY with a single aggregate (count grouped by a column)" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        group_by: p.author,
        order_by: p.author,
        select: {p.author, count(p.id)}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "GROUP BY"
    assert sql =~ "count("

    assert [{"alice", 2}, {"bob", 1}] = TestRepo.all(query)
  end

  test "GROUP BY with HAVING filtering on the aggregate result" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        group_by: p.author,
        having: count(p.id) > 1,
        select: {p.author, count(p.id)}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "GROUP BY"
    assert sql =~ "HAVING"
    assert sql =~ ~r/HAVING \(count\(.*\) > 1\)/

    assert [{"alice", 2}] = TestRepo.all(query)
  end

  test "GROUP BY on multiple columns" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        group_by: [p.author, p.id],
        order_by: [p.author, p.id],
        select: {p.author, p.id, count(p.id)}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ ~r/GROUP BY \w+\."author", \w+\."id"/

    assert [
             {"alice", 1, 1},
             {"alice", 2, 1},
             {"bob", 3, 1}
           ] = TestRepo.all(query)
  end

  test "a combined JOIN + GROUP BY query (aggregate over a joined table)" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        join: c in Comment,
        on: c.post_id == p.id,
        group_by: p.title,
        order_by: p.title,
        select: {p.title, count(c.id)}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "INNER JOIN"
    assert sql =~ "GROUP BY"

    assert [{"first post", 2}, {"second post", 1}] = TestRepo.all(query)
  end

  test "sum/avg/min/max aggregate functions render and execute correctly with GROUP BY" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        group_by: p.author,
        order_by: p.author,
        select: {p.author, sum(p.views), avg(p.views), min(p.views), max(p.views)}
      )

    assert [
             {"alice", alice_sum, _alice_avg, alice_min, alice_max},
             {"bob", 5, _bob_avg, 5, 5}
           ] = TestRepo.all(query)

    assert alice_sum == 30
    assert alice_min == 10
    assert alice_max == 20
  end

  test "count(field, :distinct) renders as count(DISTINCT field)" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        group_by: p.author,
        order_by: p.author,
        select: {p.author, count(p.title, :distinct)}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "count(DISTINCT "

    assert [{"alice", 2}, {"bob", 1}] = TestRepo.all(query)
  end

  test "filter/2 (Postgres-only FILTER-on-aggregate) raises a clear error instead of producing invalid SQL" do
    import Ecto.Query

    query =
      from(p in Post,
        group_by: p.author,
        select: {p.author, filter(count(p.id), p.views > 0)}
      )

    assert_raise Ecto.QueryError, ~r/does not support filter\/2/, fn ->
      TestRepo.all(query)
    end
  end
end
