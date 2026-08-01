defmodule Mix.Tasks.Stress.Soak do
  use Mix.Task

  @shortdoc "Holds one concurrency level steady for a long duration, sampling health over time"

  @moduledoc """
  Holds a single fixed concurrency level steady against `Stress.Repo` for
  `--duration-minutes`, printing a timestamped sample line every
  `--sample-interval-seconds` with that window's latency percentiles,
  error rate, BEAM memory, and connection-pool health, then one final
  summary across the whole run.

  `mix stress.load` ramps through concurrency levels over seconds to a
  couple of minutes and answers "does latency stay bounded as concurrency
  goes up" -- it cannot reveal a slow connection leak, a growing
  process/memory footprint, or degradation that only shows up after
  sustained load, because it never runs long enough for those to appear
  and only prints one aggregate number at the end anyway. This task holds
  concurrency fixed and trades ramp-breadth for wall-clock duration,
  printing a running series of samples instead of a single number, so a
  leak or slow-growth trend is visible as a trend across samples rather
  than hidden inside one final average.

  ## Usage

      mix stress.soak
      mix stress.soak --concurrency 10 --duration-minutes 2 --sample-interval-seconds 20
      mix stress.soak --host localhost --port 9000

  ## Options

    * `--concurrency` - number of workers held steady for the whole run
      (default `20`). Unlike `stress.load`'s `--concurrency-levels`, this
      is a single integer, not a comma list -- this task holds one level
      steady rather than ramping, so there is only ever one level to size
      for.
    * `--duration-minutes` - total wall-clock run length (default `30`).
    * `--sample-interval-seconds` - how often to print a window sample
      (default `60`).
    * `--host` / `--port` - ClickHouse native TCP host/port, defaulting
      to `localhost`/`9000` (the docker-compose defaults), matching
      `mix stress.load`/`mix stress.seed`.

  ## Pool sizing (read this before changing `--concurrency`)

  `Stress.Repo` is started once, before any worker runs, with `pool_size`
  set to `--concurrency`. This is deliberate and load-bearing, same
  reasoning as `Mix.Tasks.Stress.Load`'s moduledoc: if the pool is smaller
  than the concurrency this task drives, workers queue for a free
  connection before their query even starts, and the "query latency"
  this task prints becomes mostly pool-queue wait time, not actual
  ClickHouse query time -- silently invalidating the whole run without
  raising anything. Passing an oversized pool relative to `--concurrency`
  is harmless (idle connections just sit unused); undersizing it is the
  failure mode to avoid.

  ## Query-shape selection

  Each worker cycles through `Stress.Queries.shapes/0` round-robin (by its
  own iteration count, not randomly), same as `mix stress.load`, so
  executions are split evenly across shapes over the course of the run.

  ## Run-until-stopped workers

  `Task.async_stream`'s enumerable-driven concurrency (what `stress.load`
  uses) has no notion of "keep going until told to stop" -- it needs a
  finite enumerable up front. This task instead spawns one `Task.async/1`
  per worker running a tight loop that checks a shared `:atomics` stop
  flag between queries and exits as soon as it sees it set (finishing
  whatever query is already in flight first, never killed mid-query).
  `:atomics` rather than an `Agent`/message send: the stop flag is read
  once per query by every worker, so it needs to be cheap, lock-free, and
  have no single process that could become a bottleneck at real
  concurrency -- exactly what `:atomics` is for. Signaling stop is a
  single `:atomics.put/3`; every worker notices on its own next check and
  `Task.await/2` on each afterward blocks only as long as that worker's
  current query takes to finish.

  ## Error handling

  Each query execution is wrapped in its own `rescue`, same as
  `mix stress.load` -- one query failing does not stop its worker, and a
  pool checkout timeout is just a `DBConnection.ConnectionError` caught by
  that same `rescue` (see `Mix.Tasks.Stress.Load`'s moduledoc for how that
  was confirmed empirically). Counts are kept in `:counters` rather than
  accumulated result lists, for the same reason the stop flag uses
  `:atomics`: this run has no fixed end to collect a final list at, so
  counts need an accumulator that many worker processes can update
  concurrently without a bottleneck.

  ## Why the telemetry window is drained every sample, not accumulated

  The `[:stress, :repo, :query]` telemetry samples backing each window's
  latency/pool-wait percentiles are collected in an `Agent`, same pattern
  as `mix stress.load`. There, the run is short and ends after one
  concurrency level's fixed iteration count, so the list only ever holds
  that level's samples. Here there is no fixed iteration count -- the run
  keeps going for the full `--duration-minutes`, so if samples were left
  to accumulate in that same `Agent` for the whole run, the collector
  itself would grow without bound for the entire soak and become a
  memory-leak red herring inside the harness that's supposed to be
  *watching for* memory leaks. Each sample interval drains the collector
  (fetches its current list and resets it to `[]`) so its steady-state
  size is bounded by one interval's worth of queries, not the whole run's.
  The whole-run totals reported in the final summary come from a
  separately accumulated list built by appending each window's samples
  once per interval (a handful of appends per run, not one per query), not
  from leaving the telemetry collector itself unbounded.
  """

  alias Stress.Queries

  @default_concurrency 20
  @default_duration_minutes 30
  @default_sample_interval_seconds 60

  # Same event Ecto/DBConnection already emits -- see
  # Mix.Tasks.Stress.Load's moduledoc for the exact versions this was
  # confirmed against. Not renamed to keep both tasks' telemetry
  # attachment interchangeable/comparable.
  @query_telemetry_event [:stress, :repo, :query]

  # :counters indices.
  @ok_index 1
  @error_index 2
  @timeout_index 3

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:ecto_sql)

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          concurrency: :integer,
          duration_minutes: :integer,
          sample_interval_seconds: :integer,
          host: :string,
          port: :integer
        ]
      )

    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    duration_minutes = Keyword.get(opts, :duration_minutes, @default_duration_minutes)

    sample_interval_seconds =
      Keyword.get(opts, :sample_interval_seconds, @default_sample_interval_seconds)

    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 9000)

    # See the moduledoc's "Pool sizing" section on why this must match
    # `concurrency`, not be smaller.
    Mix.shell().info("Connecting to ClickHouse at #{host}:#{port} (pool_size #{concurrency})...")

    {:ok, _pid} =
      Stress.Repo.start_link(
        hostname: host,
        port: port,
        database: "default",
        username: "default",
        password: "",
        pool_size: concurrency,
        # This task prints its own aggregated sample lines -- Ecto's
        # per-query `[debug] QUERY OK ...` logging would drown that out
        # over a run of any real length.
        log: false
      )

    duration_ms = duration_minutes * 60_000
    interval_ms = sample_interval_seconds * 1000

    Mix.shell().info(
      "\n=== soak: concurrency #{concurrency}, #{duration_minutes}min, " <>
        "sampling every #{sample_interval_seconds}s ==="
    )

    shapes = Queries.shapes()
    shape_count = length(shapes)

    stop_flag = :atomics.new(1, signed: false)
    counters = :counters.new(3, [])

    {:ok, collector} = Agent.start_link(fn -> [] end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      @query_telemetry_event,
      &__MODULE__.handle_query_event/4,
      collector
    )

    workers =
      for _worker <- 1..concurrency do
        Task.async(fn -> worker_loop(stop_flag, shapes, shape_count, counters) end)
      end

    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + duration_ms
    first_memory = :erlang.memory()

    run_state =
      sample_loop(
        deadline,
        interval_ms,
        started_at,
        collector,
        counters,
        %{ok: 0, error: 0, timeout: 0},
        %{total_samples: [], queue_samples: [], ok: 0, error: 0, timeout: 0},
        first_memory
      )

    # Signal first, then await -- each worker finishes whatever query is
    # already in flight (never killed mid-query) and exits on its own next
    # stop-flag check, see the moduledoc's "Run-until-stopped workers".
    :atomics.put(stop_flag, 1, 1)
    Enum.each(workers, &Task.await(&1, :infinity))

    :telemetry.detach(handler_id)
    Agent.stop(collector)

    total_elapsed_ms = System.monotonic_time(:millisecond) - started_at

    print_final_summary(run_state, first_memory, total_elapsed_ms)
  end

  # Loops until `deadline`, printing one drained-window sample per
  # iteration and folding each window's counts/samples into `totals` for
  # the final whole-run summary. Sleeps `min(interval_ms, remaining)` so
  # the very last window (which may be shorter than a full interval) still
  # gets sampled and folded in before the deadline is reached, instead of
  # being skipped.
  defp sample_loop(
         deadline,
         interval_ms,
         started_at,
         collector,
         counters,
         prev_counts,
         totals,
         last_memory
       ) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    if remaining <= 0 do
      %{totals | ok: prev_counts.ok, error: prev_counts.error, timeout: prev_counts.timeout}
      |> Map.put(:last_memory, last_memory)
    else
      Process.sleep(min(interval_ms, remaining))

      window_samples = Agent.get_and_update(collector, fn samples -> {samples, []} end)

      current_counts = %{
        ok: :counters.get(counters, @ok_index),
        error: :counters.get(counters, @error_index),
        timeout: :counters.get(counters, @timeout_index)
      }

      window_ok = current_counts.ok - prev_counts.ok
      window_error = current_counts.error - prev_counts.error
      window_timeout = current_counts.timeout - prev_counts.timeout

      memory = :erlang.memory()
      elapsed_s = div(now - started_at, 1000)

      {window_total_samples, window_queue_samples} =
        Enum.reduce(window_samples, {[], []}, fn {total, queue}, {totals_acc, queues_acc} ->
          {prepend_if_present(totals_acc, total), prepend_if_present(queues_acc, queue)}
        end)

      print_sample(
        elapsed_s,
        window_ok,
        window_error,
        window_timeout,
        window_total_samples,
        window_queue_samples,
        memory
      )

      new_totals = %{
        total_samples: window_total_samples ++ totals.total_samples,
        queue_samples: window_queue_samples ++ totals.queue_samples,
        ok: 0,
        error: 0,
        timeout: 0
      }

      sample_loop(
        deadline,
        interval_ms,
        started_at,
        collector,
        counters,
        current_counts,
        new_totals,
        memory
      )
    end
  end

  # Each worker is its own tight loop rather than a fixed-count
  # `Task.async_stream` enumerable -- see the moduledoc's "Run-until-
  # stopped workers" section for why. Round-robins shapes by its own
  # running iteration count, same per-worker approach as `mix stress.load`.
  defp worker_loop(stop_flag, shapes, shape_count, counters, iteration \\ 0) do
    if :atomics.get(stop_flag, 1) == 1 do
      :ok
    else
      shape = Enum.at(shapes, rem(iteration, shape_count))
      execute_and_record(shape, counters)
      worker_loop(stop_flag, shapes, shape_count, counters, iteration + 1)
    end
  end

  # Same rescue-based error handling as `mix stress.load`'s
  # `time_execution/1` (a pool timeout is a `DBConnection.ConnectionError`
  # raised same as any other query error -- see that moduledoc's "Error
  # handling" section for how this was confirmed) but recording into
  # `:counters` instead of returning a result, since this loop has no
  # fixed end to collect a result list at.
  defp execute_and_record(shape, counters) do
    Process.put(:stress_query_shape, shape)

    try do
      Queries.execute(Stress.Repo, shape)
      :counters.add(counters, @ok_index, 1)
    rescue
      error ->
        :counters.add(counters, @error_index, 1)

        if match?(%DBConnection.ConnectionError{}, error) do
          :counters.add(counters, @timeout_index, 1)
        end
    end
  end

  @doc false
  # Same shape-attribution trick as `Mix.Tasks.Stress.Load.handle_query_event/4`
  # (this event fires synchronously in the same process as the query that
  # triggered it) except the shape itself isn't needed here -- every
  # sample window mixes all shapes together, so only the timings are kept.
  def handle_query_event(_event, measurements, _metadata, collector) do
    total_time_ms = native_to_ms(measurements[:total_time])
    queue_time_ms = native_to_ms(measurements[:queue_time])
    Agent.update(collector, fn samples -> [{total_time_ms, queue_time_ms} | samples] end)
  end

  defp native_to_ms(nil), do: nil

  defp native_to_ms(native_time),
    do: System.convert_time_unit(native_time, :native, :microsecond) / 1000

  defp prepend_if_present(list, nil), do: list
  defp prepend_if_present(list, value), do: [value | list]

  defp print_sample(
         elapsed_s,
         window_ok,
         window_error,
         window_timeout,
         total_samples,
         queue_samples,
         memory
       ) do
    total = window_ok + window_error
    error_pct = if total == 0, do: "n/a", else: "#{Float.round(window_error / total * 100, 2)}%"

    Mix.shell().info(
      "[#{timestamp()}] +#{elapsed_s}s  queries=#{total} errors=#{window_error} " <>
        "(#{window_timeout} pool timeouts) error_rate=#{error_pct}"
    )

    Mix.shell().info("    latency (ms):   #{percentile_line(total_samples)}")
    Mix.shell().info("    pool wait (ms): #{percentile_line(queue_samples)}")
    Mix.shell().info("    memory (MB):    #{memory_line(memory)}")
  end

  defp print_final_summary(run_state, first_memory, total_elapsed_ms) do
    total = run_state.ok + run_state.error

    error_pct =
      if total == 0, do: "n/a", else: "#{Float.round(run_state.error / total * 100, 2)}%"

    Mix.shell().info("\n=== soak run complete (#{div(total_elapsed_ms, 1000)}s elapsed) ===")

    Mix.shell().info(
      "total queries=#{total} errors=#{run_state.error} " <>
        "(#{run_state.timeout} pool timeouts) error_rate=#{error_pct}"
    )

    Mix.shell().info("overall latency (ms):   #{percentile_line(run_state.total_samples)}")
    Mix.shell().info("overall pool wait (ms): #{percentile_line(run_state.queue_samples)}")

    Mix.shell().info("memory (MB), first sample vs last sample:")
    Mix.shell().info("  first: #{memory_line(first_memory)}")
    Mix.shell().info("  last:  #{memory_line(run_state.last_memory)}")
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_string()

  defp memory_line(memory) do
    "total #{to_mb(memory[:total])}  processes #{to_mb(memory[:processes])}  " <>
      "binary #{to_mb(memory[:binary])}"
  end

  defp to_mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  # Copied (not shared as a public function) from
  # `Mix.Tasks.Stress.Load` -- same nearest-rank percentile approach and
  # rationale (see that module for the full comment); duplicating a
  # handful of small private helpers here is simpler and safer than
  # exporting internals of one Mix task for another to call.
  defp percentile_line([]), do: "n/a (no samples)"

  defp percentile_line(samples) do
    sorted = Enum.sort(samples)

    "p50 #{format_ms(percentile(sorted, 50))}  " <>
      "p95 #{format_ms(percentile(sorted, 95))}  " <>
      "p99 #{format_ms(percentile(sorted, 99))}"
  end

  defp percentile(sorted_samples, p) do
    count = length(sorted_samples)
    rank = (p * count / 100) |> Float.ceil() |> trunc() |> max(1) |> min(count)
    Enum.at(sorted_samples, rank - 1)
  end

  defp format_ms(ms), do: Float.round(ms * 1.0, 2)
end
