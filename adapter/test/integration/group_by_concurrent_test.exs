defmodule Ecto.Adapters.ClickHouse.GroupByConcurrentIntegrationTest do
  @moduledoc """
  Proof-of-concept for `Ecto.Adapters.ClickHouse.ConcurrentTestCase`
  (`clickhouse_adapter_elixir-v7v`): the same coverage as
  `Ecto.Adapters.ClickHouse.GroupByIntegrationTest`
  (`test/integration/group_by_test.exs`), but running `async: true` via
  per-connection `CREATE TEMPORARY TABLE` shadowing instead of a shared
  table + `TRUNCATE`. Exists to prove the new mechanism actually works
  end-to-end (including against `MergeTree`-engine tables, per the
  `ConcurrentTestCase` moduledoc's empirical finding #2) and that the full
  adapter suite still passes with this file running concurrently alongside
  the rest of the (`async: false`) suite.

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: true
  import Ecto.Adapters.ClickHouse.ConcurrentTestCase

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key false
    schema "group_by_concurrent_posts" do
      field(:id, :integer)
      field(:title, :string)
      field(:author, :string)
      field(:views, :integer)

      has_many(:comments, Ecto.Adapters.ClickHouse.GroupByConcurrentIntegrationTest.Comment,
        foreign_key: :post_id,
        references: :id
      )
    end
  end

  defmodule Comment do
    use Ecto.Schema

    @primary_key false
    schema "group_by_concurrent_comments" do
      field(:id, :integer)
      field(:post_id, :integer)
      field(:body, :string)

      belongs_to(:post, Ecto.Adapters.ClickHouse.GroupByConcurrentIntegrationTest.Post,
        foreign_key: :post_id,
        references: :id,
        define_field: false
      )
    end
  end

  setup_clickhouse_shadow_tables(TestRepo,
    group_by_concurrent_posts:
      "CREATE TABLE group_by_concurrent_posts (id UInt64, title String, author String, views UInt64) " <>
        "ENGINE = MergeTree ORDER BY id",
    group_by_concurrent_comments:
      "CREATE TABLE group_by_concurrent_comments (id UInt64, post_id UInt64, body String) " <>
        "ENGINE = MergeTree ORDER BY id"
  )

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

    assert [{"alice", 2}] = TestRepo.all(query)
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

  test "each test sees a freshly-shadowed, empty table before seeding (no cross-test leakage)" do
    import Ecto.Query
    assert [] = TestRepo.all(Post)
    assert [] = TestRepo.all(Comment)
  end
end
