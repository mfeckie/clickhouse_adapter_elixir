defmodule Stress do
  @moduledoc """
  Synthetic reporting-shaped dataset generator for ClickHouse stress-testing.

  This is a private, unpublished in-repo tool (see `mix.exs`) -- it exists
  only to seed data for a separate, later load-generation harness. It does
  not run any queries itself beyond the `CREATE`/`INSERT` statements needed
  to build the dataset; see `mix stress.seed` for the entry point.

  ## Schema

  Modeled on a typical e-commerce/product-analytics dashboard: one fact
  table plus two dimension tables.

    * `page_views` (fact) -- `id UInt64, viewed_at DateTime, user_id UInt64,
      product_id UInt64, region String, device String,
      session_duration_ms UInt32, revenue_cents Int32`.
      `ENGINE = MergeTree PARTITION BY toYYYYMM(viewed_at) ORDER BY
      (viewed_at, id)` -- partitioning by month and ordering by time first
      matches how a dashboard actually queries this table (recent-range
      scans), and is the same shape ClickHouse's own tutorials use for
      event/log-style fact tables.
    * `products` (dimension) -- `product_id UInt64, category String,
      price_cents UInt32`. Sized in the thousands, not millions -- a
      realistic catalog is orders of magnitude smaller than the traffic
      hitting it.
    * `users` (dimension) -- `user_id UInt64, signup_date Date, plan_tier
      String`. Sized in the tens of thousands, same reasoning.

  ## Skew

  A uniform-random dataset makes every dashboard query equally cheap,
  which is exactly the failure mode this generator exists to avoid --
  later load tests need queries that hit realistic hot paths (a handful of
  popular products, peak traffic hours, a dominant region) to produce
  meaningful latency numbers. Three deliberate, simple (not true-Zipfian,
  see `skewed_id/3`) skew mechanisms are used instead of `:rand.uniform/1`
  everywhere:

    * `skewed_id/3` -- a two-bucket Pareto-ish split: a small "hot" set of
      low-numbered ids (e.g. the first 10% of products) absorbs most of
      the traffic (e.g. 70%), the rest share what's left. Used for
      `product_id` and `user_id` foreign keys in the fact table, so a
      small number of products/users dominate view volume the way real
      catalogs and user bases do.
    * `weighted_pick/1` -- pick from a small explicit `{value, weight}`
      list (region, device, plan_tier, hour-of-day bucket). Cheap and
      readable for low-cardinality columns where a full distribution can
      just be written out by hand.
    * `viewed_at/1` -- day chosen uniformly across the trailing window
      (traffic doesn't meaningfully trend day-to-day over 90 days for this
      purpose), hour chosen via `weighted_pick/1` over a business-hours-
      skewed 24-bucket table, minute/second uniform. Deliberately not
      modeling day-of-week separately -- would add complexity for a skew
      dimension later load tests don't need.

  None of this needs to be statistically rigorous; it only needs to avoid
  the "every key is equally likely" trap that makes load-test numbers
  meaningless.
  """

  @regions [
    {"us-east", 35},
    {"us-west", 25},
    {"eu-west", 15},
    {"eu-central", 10},
    {"ap-southeast", 10},
    {"ap-northeast", 5}
  ]

  @devices [
    {"mobile", 55},
    {"desktop", 40},
    {"tablet", 5}
  ]

  @plan_tiers [
    {"free", 70},
    {"pro", 25},
    {"enterprise", 5}
  ]

  @categories ~w(
    electronics home-and-garden toys-and-games sports-and-outdoors
    books-and-media apparel beauty-and-personal-care grocery
    office-supplies pet-supplies automotive tools-and-hardware
    baby-and-kids health-and-wellness furniture jewelry
    musical-instruments arts-and-crafts video-games garden-and-patio
  )

  # Hour-of-day weights shaped like a typical dashboard's traffic curve --
  # low overnight, ramping through the morning, peaking in the evening.
  @hour_weights [
    {0, 2},
    {1, 1},
    {2, 1},
    {3, 1},
    {4, 1},
    {5, 2},
    {6, 3},
    {7, 5},
    {8, 7},
    {9, 8},
    {10, 8},
    {11, 8},
    {12, 9},
    {13, 8},
    {14, 8},
    {15, 8},
    {16, 9},
    {17, 10},
    {18, 11},
    {19, 11},
    {20, 10},
    {21, 8},
    {22, 5},
    {23, 3}
  ]

  @doc "The fixed category list dimension rows are assigned from."
  def categories, do: @categories

  @doc """
  Picks an id in `1..max_id` with a two-bucket Pareto-ish skew: with
  probability `hot_weight`, picks uniformly from the "hot" set (the first
  `hot_fraction` of ids); otherwise picks uniformly from the rest.

  Not true Zipfian (no per-rank weighting within either bucket) -- a flat
  hot/cold split is simpler to reason about and enough to make a handful
  of ids dominate, which is all a dashboard load test needs.
  """
  @spec skewed_id(pos_integer, float, float) :: pos_integer
  def skewed_id(max_id, hot_fraction \\ 0.1, hot_weight \\ 0.7) when max_id > 0 do
    hot_count = max(1, trunc(max_id * hot_fraction))

    if :rand.uniform() < hot_weight do
      :rand.uniform(hot_count)
    else
      cold_count = max_id - hot_count

      if cold_count > 0 do
        hot_count + :rand.uniform(cold_count)
      else
        :rand.uniform(hot_count)
      end
    end
  end

  @doc """
  Picks a value from a `[{value, weight}]` list, weight-proportional.

  Linear scan over the cumulative weight -- fine for the small
  (single-digit to couple-dozen entries) lists this is called with; not
  meant for large-cardinality distributions.
  """
  @spec weighted_pick([{term, pos_integer}]) :: term
  def weighted_pick(weighted_values) do
    total = Enum.sum(Enum.map(weighted_values, fn {_v, w} -> w end))
    roll = :rand.uniform(total)
    pick_at(weighted_values, roll)
  end

  defp pick_at([{value, weight} | rest], roll) do
    if roll <= weight, do: value, else: pick_at(rest, roll - weight)
  end

  @doc "Weighted region list, biased toward `us-east`."
  def regions, do: @regions

  @doc "Weighted device list, biased toward `mobile`."
  def devices, do: @devices

  @doc "Weighted plan-tier list, biased toward `free`."
  def plan_tiers, do: @plan_tiers

  @doc """
  A `DateTime` within the last `window_days` days, day chosen uniformly and
  hour chosen from the business-hours-skewed `@hour_weights` table (see
  moduledoc).
  """
  @spec viewed_at(pos_integer) :: DateTime.t()
  def viewed_at(window_days \\ 90) do
    day_offset = :rand.uniform(window_days) - 1
    hour = weighted_pick(@hour_weights)
    minute = :rand.uniform(60) - 1
    second = :rand.uniform(60) - 1

    DateTime.utc_now()
    |> DateTime.add(-day_offset, :day)
    |> Map.merge(%{hour: hour, minute: minute, second: second, microsecond: {0, 0}})
  end

  @doc """
  A `Date` up to `max_days_ago` days in the past, uniformly -- used for
  `users.signup_date`, where the exact distribution doesn't matter (no
  fact-table column is skewed against it).
  """
  @spec signup_date(pos_integer) :: Date.t()
  def signup_date(max_days_ago \\ 730) do
    days_ago = :rand.uniform(max_days_ago) - 1
    Date.utc_today() |> Date.add(-days_ago)
  end

  @doc """
  Session duration in milliseconds, weighted toward short (bounce-like)
  sessions with a long tail -- three buckets rather than a real
  distribution, in keeping with this generator's "good enough, not
  statistically rigorous" goal.
  """
  @spec session_duration_ms() :: pos_integer
  def session_duration_ms do
    case weighted_pick([{:short, 60}, {:medium, 30}, {:long, 10}]) do
      :short -> Enum.random(1_000..5_000)
      :medium -> Enum.random(5_001..30_000)
      :long -> Enum.random(30_001..300_000)
    end
  end

  @doc """
  Revenue in cents for a single page view. Most page views don't convert
  (`0`); a small fraction do, at a realistic-looking order value.
  """
  @spec revenue_cents() :: integer
  def revenue_cents do
    if :rand.uniform() < 0.05 do
      Enum.random(500..50_000)
    else
      0
    end
  end

  @doc """
  Escapes a string for inline use inside a ClickHouse `VALUES` literal --
  this generator only ever builds literal-value `INSERT` statements (the
  only INSERT path `ch_driver` supports today, see
  `ch_driver/test/ch_driver/query_test.exs`), so every string value that
  isn't already known-safe (e.g. hand-picked constants below) must be
  escaped before being spliced into SQL text.
  """
  @spec escape_string(String.t()) :: String.t()
  def escape_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  @doc "Formats a `DateTime` as ClickHouse's `DateTime` literal text."
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  @doc "Formats a `Date` as ClickHouse's `Date` literal text."
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date), do: Date.to_iso8601(date)
end
