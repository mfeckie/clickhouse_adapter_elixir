defmodule Ecto.Adapters.ClickHouse.FragmentIntegrationTest do
  @moduledoc """
  Live-`ClickHouse` integration coverage for `fragment/1` (see
  `Ecto.Adapters.ClickHouse.Expression.expr/3`'s `{:fragment, _, parts}`
  clause).

  `fragment/1` splices `raw`/`expr` parts directly into the generated SQL,
  giving escape-hatch access to any ClickHouse-native function or syntax
  this adapter doesn't render natively (array functions, URL functions,
  approximate aggregates, and so on). `?` placeholders inside a fragment
  go through the same expression renderer as everywhere else in a query,
  so nested Ecto expressions and parameter binding both work normally.

  The keyword-list/interpolated-fragment form (`fragment(splice: ...)`,
  or a runtime-built fragment) is explicitly unsupported, matching every
  other Ecto SQL adapter (Postgres, MyXQL) -- it raises a clear
  `Ecto.QueryError` rather than being silently mishandled.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have been run first.
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
    schema "fragment_widgets" do
      field(:id, :integer)
      field(:name, :string)
      field(:tags, {:array, :string})
    end
  end

  setup_clickhouse_tables(TestRepo,
    fragment_widgets:
      "CREATE TABLE fragment_widgets (id UInt64, name String, tags Array(String)) " <>
        "ENGINE = MergeTree ORDER BY id"
  )

  defp seed do
    TestRepo.insert!(%Widget{id: 1, name: "left-handed widget", tags: ["blue", "small"]})
    TestRepo.insert!(%Widget{id: 2, name: "right-handed widget", tags: ["red"]})
  end

  test "fragment/1 in select renders a ClickHouse-native function call" do
    seed()

    import Ecto.Query

    query =
      from(w in Widget,
        where: w.id == 1,
        select: fragment("upper(?)", w.name)
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "upper("

    assert ["LEFT-HANDED WIDGET"] = TestRepo.all(query)
  end

  test "fragment/1 in where filters using a ClickHouse-native function" do
    seed()

    import Ecto.Query

    query =
      from(w in Widget,
        where: fragment("has(?, ?)", w.tags, "red"),
        select: w.name
      )

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    assert sql =~ "has("

    assert ["right-handed widget"] = TestRepo.all(query)
  end

  test "fragment/1 splices interleaved literal text and Ecto expressions" do
    seed()

    import Ecto.Query

    query =
      from(w in Widget,
        where: w.id == 2,
        select: fragment("concat(?, ' (', toString(?), ')')", w.name, w.id)
      )

    assert ["right-handed widget (2)"] = TestRepo.all(query)
  end

  test "fragment/1 works in order_by" do
    seed()

    import Ecto.Query

    query =
      from(w in Widget,
        order_by: fragment("length(?)", w.name),
        select: w.name
      )

    assert ["left-handed widget", "right-handed widget"] = TestRepo.all(query)
  end

  test "a keyword-list fragment raises a clear Ecto.QueryError instead of silently mishandling it" do
    import Ecto.Query

    assert_raise Ecto.QueryError, ~r/does not support keyword or interpolated fragments/, fn ->
      query = from(w in Widget, select: fragment(splice: w.name))
      Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
    end
  end
end
