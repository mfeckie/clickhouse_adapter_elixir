defmodule Mix.Tasks.Stress.Load do
  use Mix.Task

  @shortdoc "Drives concurrent dashboard-style Ecto queries against the seeded dataset"

  @moduledoc """
  Ramps through fixed concurrency levels, at each level running a mix of
  the dashboard-style query shapes in `Stress.Queries` concurrently
  against `Stress.Repo`, and prints basic per-level/per-shape wall-clock
  latency (count/min/max/avg) plus any errors encountered.

  This is a load-generation harness, not a correctness test -- it exists
  to build confidence that the adapter/driver's connection pool holds up
  and latency stays bounded as concurrency ramps, against data
  `mix stress.seed` has already loaded. It does not seed data itself and
  does not assert anything about the numbers it prints; a human (or a
  later automated task) reads the output.

  A later, separately-scoped task adds telemetry-based percentile/pool
  metrics on top of this harness. This task's job is only to be
  independently runnable and useful *before* that lands -- see
  `Stress.Queries.execute/2`'s moduledoc for the single seam that later
  work hooks into; nothing here needs to change for it to land cleanly.

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
  """

  alias Stress.Queries

  @default_concurrency_levels [10, 50, 200]
  @default_iterations_per_level 20

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

    results =
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

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    print_summary(results, elapsed_ms)
  end

  # The single per-query timing wrapper mentioned in the moduledoc --
  # everything about *what* runs lives in `Stress.Queries.execute/2`, this
  # only measures wall-clock time around one call and turns a raised error
  # into a counted `:error` result instead of crashing the worker.
  defp time_execution(shape) do
    {time_us, outcome} =
      :timer.tc(fn ->
        try do
          {:ok, Queries.execute(Stress.Repo, shape)}
        rescue
          error -> {:error, error}
        end
      end)

    %{shape: shape, duration_ms: time_us / 1000, outcome: outcome}
  end

  defp print_summary(results, elapsed_ms) do
    results
    |> Enum.group_by(& &1.shape)
    |> Enum.sort_by(fn {shape, _} -> shape end)
    |> Enum.each(fn {shape, shape_results} ->
      {ok_results, error_results} =
        Enum.split_with(shape_results, fn %{outcome: outcome} -> match?({:ok, _}, outcome) end)

      durations = Enum.map(ok_results, & &1.duration_ms)

      line =
        if durations == [] do
          "  #{shape}: 0 ok, #{length(error_results)} errors"
        else
          "  #{shape}: #{length(ok_results)} ok, #{length(error_results)} errors -- " <>
            "min #{format_ms(Enum.min(durations))}ms, " <>
            "max #{format_ms(Enum.max(durations))}ms, " <>
            "avg #{format_ms(Enum.sum(durations) / length(durations))}ms"
        end

      Mix.shell().info(line)

      Enum.each(error_results, fn %{outcome: {:error, error}} ->
        Mix.shell().info("    error: #{Exception.format(:error, error, [])}" |> first_line())
      end)
    end)

    Mix.shell().info("  (wall clock for this level: #{elapsed_ms}ms)")
  end

  defp format_ms(ms), do: Float.round(ms * 1.0, 2)

  defp first_line(text), do: text |> String.split("\n") |> List.first()
end
