# stress

A private, unpublished sibling project (see `mix.exs`) with two pieces:
a seeder that loads a synthetic reporting-shaped dataset into ClickHouse
(`mix stress.seed`), and a load-generation harness that drives concurrent
dashboard-style Ecto queries against it (`mix stress.load`).

The seeder talks to ClickHouse directly via `ch_driver` (no Ecto) -- bulk
inserts don't need a query builder. The load harness talks through a real
`Ecto.Repo`/`Ecto.Adapters.ClickHouse` (via the `clickhouse_adapter_ecto`
path dependency), since the point there is exercising the real adapter and
connection pool, not raw driver queries. Both target the same
docker-compose instance `clickhouse_adapter_ecto`'s integration tests use.

## Schema and skew rationale

See `Stress`'s moduledoc (`lib/stress.ex`) for the full schema (a
`page_views` fact table plus `products` and `users` dimension tables) and
the skew approach (Pareto-ish hot/cold id buckets, weighted-list picks for
region/device/plan_tier, business-hours-skewed time-of-day).

## Running

From `clickhouse_adapter_ecto/`, start the ClickHouse container (also
brings up Kafka, unused here, but it's the same compose file the
integration tests share):

```bash
cd ../clickhouse_adapter_ecto
docker compose up -d
```

Then, from `stress/`:

```bash
mix deps.get
mix stress.seed --rows 5000000
```

`--rows` controls the `page_views` row count (default `5_000_000`);
`--host`/`--port` default to `localhost`/`9000` (the docker-compose
defaults). The task drops and recreates all three tables first, so it's
safe to re-run.

## Load-generation harness (`mix stress.load`)

Requires the dataset to already be seeded (`mix stress.seed`) -- this task
only queries what's there, it doesn't seed anything itself. From `stress/`:

```bash
mix stress.load
mix stress.load --concurrency-levels 5,20,100 --iterations-per-level 50
```

Ramps through fixed concurrency levels (`--concurrency-levels`, default
`10,50,200`), running `--iterations-per-level` (default `20`) query
executions per concurrent worker at each level, cycling round-robin
through 4 dashboard-style query shapes (region/traffic revenue, top
product categories, per-user session summary, a heavier multi-dimension
"detailed report"). See `Stress.Queries`'s moduledoc for the query shapes
and `Mix.Tasks.Stress.Load`'s moduledoc for full option docs and -- important
if you change `--concurrency-levels` -- the connection-pool-sizing
rationale (the repo's pool is sized to the highest concurrency level up
front; undersizing it just measures pool-queue wait, not query time).

Expect one block of output per concurrency level: per-shape count/errors
and min/max/avg latency in milliseconds, plus the level's total wall-clock
time. A later, separately-scoped task adds telemetry-based percentile/pool
metrics on top of this basic output.

## Resource-constrained ClickHouse for stress runs

The plain `docker compose up -d` above gives ClickHouse whatever CPU/memory
the host Docker has free, which can make local stress-test latency numbers
look better than a realistic small production deployment would. When
actually measuring stress-test numbers (as opposed to just running
integration tests), layer on `docker-compose.stress.yml` to cap the
`clickhouse` service to 2 CPUs / 4GB memory -- a reasonable small-instance
production baseline:

```bash
cd ../clickhouse_adapter_ecto
docker compose -f docker-compose.yml -f docker-compose.stress.yml up -d
```

Tear it down the same way when done:

```bash
docker compose -f docker-compose.yml -f docker-compose.stress.yml down
```

This is opt-in and only for stress runs -- normal (non-stress) integration
test runs should keep using the plain `docker compose up -d` (unconstrained)
above, since capping resources isn't relevant there and would only slow
down the test suite.
