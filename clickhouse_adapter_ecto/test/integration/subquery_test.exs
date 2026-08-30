defmodule Ecto.Adapters.ClickHouse.SubqueryIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for `field in subquery(inner_query)`
  (non-correlated) in `WHERE` position -- see the `expr({:in, _, [left,
  %Ecto.SubQuery{}]})`/`expr(%Ecto.SubQuery{})` clauses in
  `Ecto.Adapters.ClickHouse.Expression` and `subquery_as_prefix/1` there for
  the implementation.

  Correlated/lateral subqueries remain unsupported, same rationale as the
  `LATERAL JOIN` rejection documented on
  `Ecto.Adapters.ClickHouse.Expression` -- not covered here.

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

  defmodule Teacher do
    use Ecto.Schema

    @primary_key false
    schema "subquery_teachers" do
      field(:id, :integer)
      field(:name, :string)
      field(:active, :boolean)
    end
  end

  defmodule Assignment do
    use Ecto.Schema

    @primary_key false
    schema "subquery_assignments" do
      field(:id, :integer)
      field(:teacher_id, :integer)
      field(:title, :string)
    end
  end

  setup_clickhouse_tables(TestRepo,
    subquery_teachers:
      "CREATE TABLE subquery_teachers (id UInt64, name String, active UInt8) " <>
        "ENGINE = MergeTree ORDER BY id",
    subquery_assignments:
      "CREATE TABLE subquery_assignments (id UInt64, teacher_id UInt64, title String) " <>
        "ENGINE = MergeTree ORDER BY id"
  )

  defp seed do
    TestRepo.insert!(%Teacher{id: 1, name: "Ada", active: true})
    TestRepo.insert!(%Teacher{id: 2, name: "Bob", active: false})
    TestRepo.insert!(%Teacher{id: 3, name: "Cleo", active: true})

    TestRepo.insert!(%Assignment{id: 1, teacher_id: 1, title: "Essay"})
    TestRepo.insert!(%Assignment{id: 2, teacher_id: 2, title: "Quiz"})
    TestRepo.insert!(%Assignment{id: 3, teacher_id: 3, title: "Lab"})
    TestRepo.insert!(%Assignment{id: 4, teacher_id: 1, title: "Homework"})
  end

  test "field in subquery(inner_query) compiles to `IN (SELECT` and returns matching rows" do
    seed()

    active_teacher_ids = from(t in Teacher, where: t.active == true, select: t.id)

    query =
      from(a in Assignment,
        where: a.teacher_id in subquery(active_teacher_ids),
        select: a.title,
        order_by: a.title
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    refute sql =~ "fragment"
    assert sql =~ ~r/"teacher_id" IN \(SELECT/

    assert TestRepo.all(query) == ["Essay", "Homework", "Lab"]
  end

  test "params from both the outer WHERE and the inner subquery's WHERE thread correctly" do
    seed()

    # Inner subquery filters teachers by `name` with its own pinned param.
    # Outer query filters assignments by `title` with a different pinned
    # param. If params were misordered/misaligned across the subquery
    # boundary, one (or both) of these filters would apply to the wrong
    # placeholder and either raise or return wrong rows.
    teacher_ids_named_ada =
      from(t in Teacher, where: t.name == ^"Ada", select: t.id)

    query =
      from(a in Assignment,
        where: a.title != ^"Homework",
        where: a.teacher_id in subquery(teacher_ids_named_ada),
        select: a.title
      )

    assert TestRepo.all(query) == ["Essay"]
  end
end
