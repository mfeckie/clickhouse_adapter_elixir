defmodule Mix.Tasks.Stress.Seed do
  use Mix.Task

  @shortdoc "Seeds a synthetic reporting dataset into ClickHouse for stress-testing"

  @moduledoc """
  Drops and recreates the `products`, `users`, and `page_views` tables (see
  `Stress`'s moduledoc for the schema and skew rationale) against a
  docker-compose ClickHouse instance, then seeds them: dimension tables
  first, then the fact table via batched `INSERT`s.

  ## Usage

      mix stress.seed
      mix stress.seed --rows 1000000
      mix stress.seed --rows 5000000 --host localhost --port 9000

  ## Options

    * `--rows` - fact-table (`page_views`) row count. Defaults to
      `5_000_000`.
    * `--host` - ClickHouse hostname. Defaults to `localhost`.
    * `--port` - ClickHouse native TCP port. Defaults to `9000` (the
      docker-compose default in `clickhouse_adapter_ecto/docker-compose.yml`).

  Safe to re-run -- every table is dropped and recreated before seeding.
  """

  alias Stress

  # A realistic catalog/user-base size relative to the (millions-row)
  # fact table -- see `Stress`'s moduledoc on dimension tables being
  # orders of magnitude smaller than the traffic hitting them.
  @products_count 5_000
  @users_count 50_000

  # Rows per INSERT statement. Large enough to keep round-trip overhead
  # off the critical path, small enough that no single INSERT string (or
  # the server-side memory to parse it) balloons -- never build one
  # giant multi-million-row VALUES string.
  @batch_size 5_000

  # How often (in batches) to log progress for the fact table, so a human
  # watching stdout can tell the seed is alive and roughly how far along.
  @progress_every_batches 20

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ch_driver)

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [rows: :integer, host: :string, port: :integer]
      )

    rows = Keyword.get(opts, :rows, 5_000_000)
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 9000)

    Mix.shell().info("Connecting to ClickHouse at #{host}:#{port}...")
    {:ok, pool} = ChDriver.start_link(hostname: host, port: port, pool_size: 4)

    create_schema(pool)
    seed_products(pool)
    seed_users(pool)
    seed_page_views(pool, rows)

    Mix.shell().info(
      "Done. Seeded #{@products_count} products, #{@users_count} users, " <>
        "#{rows} page_views."
    )
  end

  defp create_schema(pool) do
    Mix.shell().info("Creating schema...")

    ChDriver.query!(pool, "DROP TABLE IF EXISTS page_views")
    ChDriver.query!(pool, "DROP TABLE IF EXISTS products")
    ChDriver.query!(pool, "DROP TABLE IF EXISTS users")

    ChDriver.query!(pool, """
    CREATE TABLE products (
      product_id UInt64,
      category String,
      price_cents UInt32
    ) ENGINE = MergeTree ORDER BY product_id
    """)

    ChDriver.query!(pool, """
    CREATE TABLE users (
      user_id UInt64,
      signup_date Date,
      plan_tier String
    ) ENGINE = MergeTree ORDER BY user_id
    """)

    ChDriver.query!(pool, """
    CREATE TABLE page_views (
      id UInt64,
      viewed_at DateTime,
      user_id UInt64,
      product_id UInt64,
      region String,
      device String,
      session_duration_ms UInt32,
      revenue_cents Int32
    ) ENGINE = MergeTree
    PARTITION BY toYYYYMM(viewed_at)
    ORDER BY (viewed_at, id)
    """)
  end

  defp seed_products(pool) do
    Mix.shell().info("Seeding #{@products_count} products...")

    1..@products_count
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn ids ->
      values =
        Enum.map_join(ids, ",", fn product_id ->
          category = Stress.escape_string(Enum.random(Stress.categories()))
          price_cents = Enum.random(199..49_999)
          "(#{product_id},'#{category}',#{price_cents})"
        end)

      ChDriver.query!(
        pool,
        "INSERT INTO products (product_id, category, price_cents) VALUES " <> values
      )
    end)
  end

  defp seed_users(pool) do
    Mix.shell().info("Seeding #{@users_count} users...")

    1..@users_count
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn ids ->
      values =
        Enum.map_join(ids, ",", fn user_id ->
          signup_date = Stress.format_date(Stress.signup_date())
          plan_tier = Stress.weighted_pick(Stress.plan_tiers())
          "(#{user_id},'#{signup_date}','#{plan_tier}')"
        end)

      ChDriver.query!(
        pool,
        "INSERT INTO users (user_id, signup_date, plan_tier) VALUES " <> values
      )
    end)
  end

  defp seed_page_views(pool, rows) do
    Mix.shell().info("Seeding #{rows} page_views (batch size #{@batch_size})...")

    total_batches = Integer.floor_div(rows + @batch_size - 1, @batch_size)
    started_at = System.monotonic_time(:millisecond)

    0..(total_batches - 1)
    |> Enum.each(fn batch_index ->
      batch_start_id = batch_index * @batch_size + 1
      batch_row_count = min(@batch_size, rows - batch_index * @batch_size)

      values =
        batch_start_id..(batch_start_id + batch_row_count - 1)
        |> Enum.map_join(",", &page_view_row/1)

      ChDriver.query!(
        pool,
        "INSERT INTO page_views (id, viewed_at, user_id, product_id, region, device, " <>
          "session_duration_ms, revenue_cents) VALUES " <> values
      )

      if rem(batch_index + 1, @progress_every_batches) == 0 or batch_index == total_batches - 1 do
        log_progress(
          batch_index + 1,
          total_batches,
          batch_start_id + batch_row_count - 1,
          rows,
          started_at
        )
      end
    end)
  end

  defp page_view_row(id) do
    viewed_at = Stress.format_datetime(Stress.viewed_at())
    user_id = Stress.skewed_id(@users_count)
    product_id = Stress.skewed_id(@products_count)
    region = Stress.weighted_pick(Stress.regions())
    device = Stress.weighted_pick(Stress.devices())
    session_duration_ms = Stress.session_duration_ms()
    revenue_cents = Stress.revenue_cents()

    "(#{id},'#{viewed_at}',#{user_id},#{product_id},'#{region}','#{device}'," <>
      "#{session_duration_ms},#{revenue_cents})"
  end

  defp log_progress(batches_done, total_batches, rows_done, total_rows, started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    pct = Float.round(rows_done / total_rows * 100, 1)

    Mix.shell().info(
      "  #{batches_done}/#{total_batches} batches, #{rows_done}/#{total_rows} rows " <>
        "(#{pct}%), #{elapsed_ms}ms elapsed"
    )
  end
end
