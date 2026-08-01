defmodule Stress.Queries do
  @moduledoc """
  Dashboard-style query shapes `mix stress.load` drives concurrently
  against the dataset `mix stress.seed` populates. Each shape is a real
  `Ecto.Query` built through the `Stress.PageView`/`Stress.Product`/
  `Stress.User` schemas (see `stress/lib/stress/repo.ex`) -- no raw SQL
  fragments are needed for any of these; plain `join`/`group_by`/
  `order_by`/aggregate-function queries already round-trip through
  `Ecto.Adapters.ClickHouse` per `clickhouse_adapter_ecto`'s own
  `join_test.exs`/`group_by_test.exs` integration coverage.

  `execute/2` is the single hook point later telemetry-based
  instrumentation work is meant to wrap: it takes a repo and a shape atom,
  runs exactly one query, and returns the result. Timing (or any other
  per-call instrumentation) belongs *around* this call, not inside it --
  `Mix.Tasks.Stress.Load` currently wraps it with `:timer.tc/1` for basic
  wall-clock min/max/avg reporting, and a later telemetry-percentile task
  can wrap the same call (or attach to the `[:stress, :repo, :query]`
  telemetry events `Ecto.Repo` already emits) without this module
  changing.
  """

  import Ecto.Query

  alias Stress.{PageView, Product, User}

  @shapes [:region_revenue, :top_products, :user_sessions, :detailed_report]

  @doc "The fixed list of query shapes `mix stress.load` cycles/picks through."
  def shapes, do: @shapes

  @doc """
  Runs one query shape against `repo` and returns its result rows.

  This is the single instrumentation seam described in the moduledoc --
  keep it to "build a query, call `repo.all/1`, return" so a caller can
  time (or otherwise wrap) exactly one query execution without reaching
  into shape-specific logic.
  """
  @spec execute(module, atom) :: [map]
  def execute(repo, shape) when shape in @shapes do
    shape |> query() |> repo.all()
  end

  @doc """
  Revenue/traffic by region over a recent time window -- the classic
  filtered-aggregation dashboard tile ("how are we doing by region this
  week").
  """
  def region_revenue(window_days \\ 7) do
    cutoff = recent_cutoff(window_days)

    from(pv in PageView,
      where: pv.viewed_at >= ^cutoff,
      group_by: pv.region,
      order_by: [desc: sum(pv.revenue_cents)],
      select: %{
        region: pv.region,
        views: count(pv.id),
        revenue_cents: sum(pv.revenue_cents)
      }
    )
  end

  @doc """
  Top product categories by revenue -- a `page_views`-to-`products` JOIN
  aggregated and ranked, the "what's selling" tile. Grouping by
  `category` rather than raw `product_id` keeps the result set small
  (tens of rows, matching `products.category`'s cardinality) regardless
  of catalog size.
  """
  def top_products(limit \\ 10) do
    from(pv in PageView,
      join: p in Product,
      on: pv.product_id == p.product_id,
      group_by: p.category,
      order_by: [desc: sum(pv.revenue_cents)],
      limit: ^limit,
      select: %{
        category: p.category,
        views: count(pv.id),
        revenue_cents: sum(pv.revenue_cents)
      }
    )
  end

  @doc """
  Per-user session summary for a given plan tier -- a `page_views`-to-
  `users` JOIN filtered by `plan_tier` and aggregated per user, the "top
  engaged customers" tile.
  """
  def user_sessions(plan_tier \\ "pro", limit \\ 20) do
    from(pv in PageView,
      join: u in User,
      on: pv.user_id == u.user_id,
      where: u.plan_tier == ^plan_tier,
      group_by: pv.user_id,
      order_by: [desc: sum(pv.session_duration_ms)],
      limit: ^limit,
      select: %{
        user_id: pv.user_id,
        sessions: count(pv.id),
        total_duration_ms: sum(pv.session_duration_ms)
      }
    )
  end

  @doc """
  The "detailed report" tile -- a wider, heavier multi-dimension GROUP BY
  (region x device x category) over a longer window than
  `region_revenue/1`, standing in for the kind of drill-down report a
  dashboard offers alongside its summary tiles. Returns a larger result
  set (bounded by region/device/category cardinality, still small, but
  wider per row and one more JOIN than `region_revenue/1`) and does
  meaningfully more aggregation work per call, which is the point --
  representing the heavy end of the query mix.
  """
  def detailed_report(window_days \\ 30) do
    cutoff = recent_cutoff(window_days)

    from(pv in PageView,
      join: p in Product,
      on: pv.product_id == p.product_id,
      where: pv.viewed_at >= ^cutoff,
      group_by: [pv.region, pv.device, p.category],
      select: %{
        region: pv.region,
        device: pv.device,
        category: p.category,
        views: count(pv.id),
        revenue_cents: sum(pv.revenue_cents)
      }
    )
  end

  defp query(:region_revenue), do: region_revenue()
  defp query(:top_products), do: top_products()
  defp query(:user_sessions), do: user_sessions()
  defp query(:detailed_report), do: detailed_report()

  # NaiveDateTime, not DateTime -- `page_views.viewed_at` maps to a
  # `:naive_datetime` field (see `Stress.PageView`), matching how
  # `clickhouse_adapter_ecto`'s own `repo_advanced_test.exs` maps a plain
  # ClickHouse `DateTime` column (timezone-naive on the wire either way).
  defp recent_cutoff(window_days) do
    NaiveDateTime.add(NaiveDateTime.utc_now(), -window_days * 86_400, :second)
  end
end
