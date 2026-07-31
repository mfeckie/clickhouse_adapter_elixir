defmodule Ecto.Adapters.ClickHouse.JoinIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for JOIN support (see
  `Ecto.Adapters.ClickHouse.Expression.join/2` and
  `Ecto.Adapters.ClickHouse.QueryBuilder.all/2`).

  Only `:inner` and `:left` joins against an explicit `ON` condition are
  supported -- the common case for `Ecto.Query`'s `join/4,5` and
  association-based (`join: assoc(...)`, `has_many`/`belongs_to`) queries.
  `:right`/`:full`/`:cross` and any ClickHouse-specific ASOF/semi/anti/
  lateral/array join are explicitly out of scope and raise a clear
  `Ecto.QueryError` instead of being silently mishandled -- see
  `Ecto.Adapters.ClickHouse.Expression`'s moduledoc-adjacent comment above
  `join/2` for the full rationale (in short: a plain ClickHouse
  `INNER`/`LEFT JOIN ... ON ...` needs no `ALL`/`ANY` strictness qualifier
  for a simple equality condition against this repo's pinned
  `clickhouse/clickhouse-server:24.8` image, so the generated SQL stays
  the same standard-SQL shape other Ecto adapters produce).

  `delete_all/2` with joins remains unsupported (ClickHouse's
  `ALTER TABLE ... DELETE` mutation has no join support) -- see the
  updated error message in `QueryBuilder.delete_all/1`.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.

  Test isolation here uses `Ecto.Adapters.ClickHouse.TestCase` (see its
  moduledoc for the full rationale) instead of the hand-rolled
  `setup_all`/`setup`/`on_exit` boilerplate every other file in this
  directory still has: `Ecto.Adapter.Transaction` (and therefore
  `Ecto.Adapters.SQL.Sandbox`) doesn't work against this adapter --
  confirmed empirically, `Repo.transaction/2` raises a
  `DBConnection.ConnectionError` -- so this is a shared-table,
  `TRUNCATE`-before-each-test reset instead of a rolled-back transaction.
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
    schema "join_posts" do
      field(:id, :integer)
      field(:title, :string)
      has_many(:comments, Ecto.Adapters.ClickHouse.JoinIntegrationTest.Comment, foreign_key: :post_id, references: :id)
    end
  end

  defmodule Comment do
    use Ecto.Schema

    @primary_key false
    schema "join_comments" do
      field(:id, :integer)
      field(:post_id, :integer)
      field(:body, :string)
      belongs_to(:post, Ecto.Adapters.ClickHouse.JoinIntegrationTest.Post, foreign_key: :post_id, references: :id, define_field: false)
    end
  end

  setup_clickhouse_tables TestRepo,
    join_posts: "CREATE TABLE join_posts (id UInt64, title String) ENGINE = MergeTree ORDER BY id",
    join_comments:
      "CREATE TABLE join_comments (id UInt64, post_id UInt64, body String) " <>
        "ENGINE = MergeTree ORDER BY id"

  defp seed do
    TestRepo.insert!(%Post{id: 1, title: "first post"})
    TestRepo.insert!(%Post{id: 2, title: "second post"})

    TestRepo.insert!(%Comment{id: 100, post_id: 1, body: "nice post"})
    TestRepo.insert!(%Comment{id: 101, post_id: 1, body: "another comment"})
    TestRepo.insert!(%Comment{id: 102, post_id: 2, body: "on second post"})
  end

  test "a basic two-table INNER JOIN via join/4 with an explicit ON condition, selecting fields from both sides" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        join: c in Comment,
        on: c.post_id == p.id,
        where: p.id == 1,
        order_by: c.id,
        select: {p.title, c.body}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

    assert sql =~ "INNER JOIN"
    assert sql =~ ~r/ON \w+\."post_id" = \w+\."id"/

    assert [
             {"first post", "nice post"},
             {"first post", "another comment"}
           ] = TestRepo.all(query)
  end

  test "a LEFT JOIN via join/4 includes rows from the left side with no match" do
    seed()

    # A post with no comments at all -- must still show up via LEFT JOIN,
    # unlike an INNER JOIN which would drop it entirely.
    TestRepo.insert!(%Post{id: 3, title: "orphan post"})

    import Ecto.Query

    query =
      from(p in Post,
        left_join: c in Comment,
        on: c.post_id == p.id,
        where: p.id == 3,
        select: {p.title, c.body}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "LEFT JOIN"

    # `join_comments.body` is a plain (non-`Nullable`) `String` column, so
    # ClickHouse's default (non-`join_use_nulls`) LEFT JOIN behaviour fills
    # the unmatched right side with that type's *default* value -- `""` for
    # `String` -- rather than SQL `NULL`. This is a real, documented
    # ClickHouse dialect difference from Postgres/MySQL (where a LEFT JOIN
    # always yields NULL for an unmatched right side); nothing in this
    # adapter's JOIN support tries to paper over it, so the test asserts
    # the actual ClickHouse behaviour rather than the SQL-standard one.
    assert [{"orphan post", ""}] = TestRepo.all(query)
  end

  test "a join through a schema association (join: assoc(p, :comments)) works via the same code path" do
    seed()

    import Ecto.Query

    query =
      from(p in Post,
        join: c in assoc(p, :comments),
        where: p.id == 1,
        order_by: c.id,
        select: {p.title, c.body}
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "INNER JOIN"

    assert [
             {"first post", "nice post"},
             {"first post", "another comment"}
           ] = TestRepo.all(query)
  end

  test "an unsupported join qualifier (:right) raises a clear Ecto.QueryError instead of silently mishandling it" do
    import Ecto.Query

    query =
      from(p in Post,
        right_join: c in Comment,
        on: c.post_id == p.id,
        select: {p.title, c.body}
      )

    assert_raise Ecto.QueryError, ~r/only supports :inner and :left joins/, fn ->
      TestRepo.all(query)
    end
  end

  test "delete_all/2 with a join still raises a clear, documented error (ALTER TABLE ... DELETE has no join support)" do
    import Ecto.Query

    query =
      from(p in Post,
        join: c in Comment,
        on: c.post_id == p.id
      )

    assert_raise Ecto.QueryError, ~r/does not support joins in delete_all\/2/, fn ->
      TestRepo.delete_all(query)
    end
  end
end
