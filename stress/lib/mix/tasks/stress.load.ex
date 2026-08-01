defmodule Mix.Tasks.Stress.Load do
  use Mix.Task

  @shortdoc "Drives concurrent dashboard-style Ecto queries against the seeded dataset"

  @moduledoc """
  Ramps through fixed concurrency levels, at each level running a mix of
  the dashboard-style query shapes in `Stress.Queries` concurrently
  against `Stress.Repo`, and prints per-level/per-shape latency
  percentiles (p50/p95/p99) plus pool checkout-wait percentiles and
  error/timeout counts.

  This is a load-generation harness, not a correctness test -- it exists
  to build confidence that the adapter/driver's connection pool holds up
  and latency stays bounded as concurrency ramps, against data
  `mix stress.seed` has already loaded. It does not seed data itself and
  does not assert anything about the numbers it prints; a human (or a
  later automated task) reads the output.

  Percentiles instead of min/max/avg: min/max/avg tells you almost
  nothing about whether latency stays bounded under concurrency -- a
  single slow outlier moves max but says nothing about what most
  requests experience, and avg is dragged around by the same outliers
  it's supposed to summarize away. p95/p99 are what actually expose
  tail-latency blowup as concurrency ramps.

  Pool checkout-wait (queue_time) alongside total latency: without it,
  "queries got slow" and "the connection pool is the bottleneck" look
  identical from the outside. Reported separately, a level where
  queue_time tracks total_time upward says the pool is the bottleneck; a
  level where queue_time stays flat while total_time grows says
  ClickHouse itself is the bottleneck.

  Both come from the `[:stress, :repo, :query]` telemetry event
  `Ecto.Repo`/`Ecto.Adapters.SQL` already emits on every query (confirmed
  against ecto 3.14.1 / ecto_sql 3.14.0 / db_connection 2.10.2, the
  versions this project's `mix.lock` pins) -- see `handle_query_event/4`.
  `Stress.Queries.execute/2` itself is untouched; this task only wraps it
  more thoroughly than before.

  ## Usage

      mix stress.load
      mix stress.load --concurrency-levels 5,20,100 --iterations-per-level 50
      mix stress.load --host localhost --port 9000

  ## Options

    * `--concurrency-levels` - comma-separated list of worker counts to
      ramp through, in order, e.g. `10,50,200` (the default). Each level
      runs to completion before the next starts.
    * `--iterations-per-level` - how many query executions *each worker*
      runs at a given concurrency level (not a total across all workers).
      Defaults to `20` -- so concurrency level `N` executes `N *
      iterations_per_level` queries total, split evenly across `N`
      concurrent workers. Kept per-worker (rather than a single shared
      total) so every worker does the same amount of work regardless of
      `N`, making levels comparable to each other.
    * `--host` / `--port` - ClickHouse native TCP host/port, defaulting
      to `localhost`/`9000` (the docker-compose defaults), matching
      `mix stress.seed`.

  ## Pool sizing (read this before changing `--concurrency-levels`)

  `Stress.Repo` is started once, before any concurrency level runs, with
  `pool_size` set to the *highest* value in `--concurrency-levels`. This
  is deliberate and load-bearing: if the pool is smaller than the
  concurrency level being driven at any point, workers queue for a free
  connection before their query even starts, and the "query latency"
  this task prints becomes mostly pool-queue wait time, not actual
  ClickHouse query time -- silently invalidating the whole run without
  raising anything. This is the same gotcha
  `clickhouse_adapter_ecto/test/support/concurrent_test_case.ex`'s
  moduledoc documents for its own `Ownership` pool ("`pool_size` must be
  >= the number of test processes that will concurrently hold a
  checkout"). Passing an oversized pool relative to the *lowest*
  concurrency level is harmless (idle connections just sit unused) --
  undersizing relative to the *highest* level is the failure mode to
  avoid.

  ## Query-shape selection

  Each worker cycles through `Stress.Queries.shapes/0` round-robin (by
  iteration index, not randomly) -- this guarantees an even, reproducible
  split of executions across shapes at every concurrency level, so
  per-shape counts are directly comparable across levels without relying
  on random-number luck evening out over `iterations_per_level` samples.

  ## Error handling

  Each individual query execution is wrapped in its own `rescue` -- one
  query failing (a ClickHouse error, a connection blip) is counted as an
  error for that shape and does not stop the worker, the concurrency
  level, or the run.

  A connection-pool checkout timeout (worker waited for a free connection
  longer than `:queue_target`/`:queue_interval` allow) is *also* just a
  raised `DBConnection.ConnectionError`, caught by that same `rescue` --
  confirmed empirically (not assumed) by racing queries against a
  single-connection pool and observing both (a) the
  `[:stress, :repo, :query]` telemetry event still firing, with only
  `queue_time`/`total_time` present (no `query_time` -- the query itself
  never ran), and (b) `Repo.all/2` raising `DBConnection.ConnectionError`
  up to the caller same as any other query error. So a pool timeout is
  never silently dropped: it shows up both as a `queue_time` sample and
  as a counted error/timeout below.
  """

  alias Stress.Queries

  @default_concurrency_levels [10, 50, 200]
  @default_iterations_per_level 20

  # Ecto's own event, not something this task invents -- see the
  # moduledoc for the exact Ecto/DBConnection versions this was
  # confirmed against.
  @query_telemetry_event [:stress, :repo, :query]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ecto_sql)

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          concurrency_levels: :string,
          iterations_per_level: :integer,
          host: :string,
          port: :integer
        ]
      )

    concurrency_levels = parse_concurrency_levels(opts)
    iterations_per_level = Keyword.get(opts, :iterations_per_level, @default_iterations_per_level)
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 9000)

    # Sized for the highest level up front -- see the moduledoc's "Pool
    # sizing" section on why undersizing this silently invalidates every
    # number this task prints.
    pool_size = Enum.max(concurrency_levels)

    Mix.shell().info("Connecting to ClickHouse at #{host}:#{port} (pool_size #{pool_size})...")

    {:ok, _pid} =
      Stress.Repo.start_link(
        hostname: host,
        port: port,
        database: "default",
        username: "default",
        password: "",
        pool_size: pool_size,
        # This task prints its own aggregated timing summary -- Ecto's
        # per-query `[debug] QUERY OK ...` logging would otherwise drown
        # that out at any real concurrency level.
        log: false
      )

    Enum.each(concurrency_levels, fn concurrency ->
      run_level(concurrency, iterations_per_level)
    end)
  end

  defp parse_concurrency_levels(opts) do
    case Keyword.get(opts, :concurrency_levels) do
      nil ->
        @default_concurrency_levels

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_integer/1)
    end
  end

  defp run_level(concurrency, iterations_per_level) do
    Mix.shell().info(
      "\n=== concurrency #{concurrency} (#{iterations_per_level} iterations/worker, " <>
        "#{concurrency * iterations_per_level} queries total) ==="
    )

    shapes = Queries.shapes()
    shape_count = length(shapes)

    started_at = System.monotonic_time(:millisecond)

    # One handler per level, always detached in `after` -- a `make_ref/0`
    # id guarantees no collision with a handler from a previous level or a
    # previous `mix stress.load` run still lingering (telemetry handlers
    # are global/process-independent, so a leaked one would keep firing
    # into a dead collector and silently double-count on the next level).
    {:ok, collector} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, make_ref()}

    results =
      try do
        :telemetry.attach(
          handler_id,
          @query_telemetry_event,
          &__MODULE__.handle_query_event/4,
          collector
        )

        1..concurrency
        |> Task.async_stream(
          fn _worker ->
            Enum.map(0..(iterations_per_level - 1), fn i ->
              shape = Enum.at(shapes, rem(i, shape_count))
              time_execution(shape)
            end)
          end,
          max_concurrency: concurrency,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, worker_results} -> worker_results end)
      after
        :telemetry.detach(handler_id)
      end

    telemetry_samples = Agent.get(collector, & &1)
    Agent.stop(collector)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    print_summary(results, telemetry_samples, elapsed_ms)
  end

  # `Queries.execute/2` runs synchronously in this worker process and,
  # underneath, so does Ecto/DBConnection's own telemetry callback for it
  # (no spawn in between) -- so stashing the shape here in the process
  # dictionary right before the call is a safe way for
  # `handle_query_event/4` to attribute the event it receives a moment
  # later back to the shape that produced it. The event's own metadata
  # only carries the query's source table (`"page_views"` for every shape
  # here, since that's every shape's base `from`), so it can't
  # distinguish shapes on its own.
  #
  # The `rescue` is still what turns a raised error (a ClickHouse error, a
  # connection blip, a pool checkout timeout -- see the moduledoc's
  # "Error handling" section) into a counted `:error` result instead of
  # crashing the worker; wall-clock timing itself is no longer measured
  # here since the telemetry event's own `total_time` (collected by
  # `handle_query_event/4`) is the more accurate number for percentiles.
  defp time_execution(shape) do
    Process.put(:stress_query_shape, shape)

    outcome =
      try do
        {:ok, Queries.execute(Stress.Repo, shape)}
      rescue
        error -> {:error, error}
      end

    %{shape: shape, outcome: outcome}
  end

  @doc false
  # Runs in the same process as the query that triggered it (see
  # `time_execution/1`). `measurements` keys are native time units and
  # only present when non-nil (Ecto drops nil components rather than
  # sending zeroes) -- a pool checkout timeout means `query_time`/
  # `decode_time` are absent, since the query itself never ran, but
  # `queue_time`/`total_time` are always there.
  def handle_query_event(_event, measurements, _metadata, collector) do
    shape = Process.get(:stress_query_shape)
    total_time_ms = native_to_ms(measurements[:total_time])
    queue_time_ms = native_to_ms(measurements[:queue_time])

    Agent.update(collector, fn samples -> [{shape, total_time_ms, queue_time_ms} | samples] end)
  end

  defp native_to_ms(nil), do: nil

  defp native_to_ms(native_time),
    do: System.convert_time_unit(native_time, :native, :microsecond) / 1000

  defp print_summary(results, telemetry_samples, elapsed_ms) do
    telemetry_by_shape = Enum.group_by(telemetry_samples, fn {shape, _total, _queue} -> shape end)

    results
    |> Enum.group_by(& &1.shape)
    |> Enum.sort_by(fn {shape, _} -> shape end)
    |> Enum.each(fn {shape, shape_results} ->
      {ok_results, error_results} =
        Enum.split_with(shape_results, fn %{outcome: outcome} -> match?({:ok, _}, outcome) end)

      # `DBConnection.ConnectionError` is what a pool checkout timeout
      # raises (see the moduledoc) -- singled out here so a run can tell
      # "ClickHouse rejected/errored some queries" apart from "the pool
      # couldn't keep up with this concurrency level" at a glance.
      timeout_count =
        Enum.count(error_results, fn %{outcome: {:error, error}} ->
          match?(%DBConnection.ConnectionError{}, error)
        end)

      {total_samples, queue_samples} =
        shape
        |> then(&Map.get(telemetry_by_shape, &1, []))
        |> Enum.reduce({[], []}, fn {_shape, total, queue}, {totals, queues} ->
          {prepend_if_present(totals, total), prepend_if_present(queues, queue)}
        end)

      Mix.shell().info(
        "  #{shape}: #{length(ok_results)} ok, #{length(error_results)} errors " <>
          "(#{timeout_count} pool timeouts)"
      )

      Mix.shell().info("    latency (ms):   #{percentile_line(total_samples)}")
      Mix.shell().info("    pool wait (ms): #{percentile_line(queue_samples)}")

      Enum.each(error_results, fn %{outcome: {:error, error}} ->
        Mix.shell().info("    error: #{Exception.format(:error, error, [])}" |> first_line())
      end)
    end)

    Mix.shell().info("  (wall clock for this level: #{elapsed_ms}ms)")
  end

  defp prepend_if_present(list, nil), do: list
  defp prepend_if_present(list, value), do: [value | list]

  defp percentile_line([]), do: "n/a (no samples)"

  defp percentile_line(samples) do
    sorted = Enum.sort(samples)

    "p50 #{format_ms(percentile(sorted, 50))}  " <>
      "p95 #{format_ms(percentile(sorted, 95))}  " <>
      "p99 #{format_ms(percentile(sorted, 99))}"
  end

  # Nearest-rank percentile: pick the sample at position `ceil(p/100 * n)`
  # in the sorted list, no interpolation between adjacent ranks. That's a
  # coarser estimate than interpolated methods, but it's simple to read
  # and audit, and at the sample sizes this harness collects (tens to a
  # few thousand per shape/level) interpolation wouldn't move the number
  # by anything that matters against tail-latency blowup, which is what
  # this is for.
  defp percentile(sorted_samples, p) do
    count = length(sorted_samples)
    rank = (p * count / 100) |> Float.ceil() |> trunc() |> max(1) |> min(count)
    Enum.at(sorted_samples, rank - 1)
  end

  defp format_ms(ms), do: Float.round(ms * 1.0, 2)

  defp first_line(text), do: text |> String.split("\n") |> List.first()
end
