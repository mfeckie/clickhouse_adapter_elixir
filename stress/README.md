# stress

A private, unpublished sibling project (see `mix.exs`) that seeds a
synthetic reporting-shaped dataset into ClickHouse for later stress-test/
load-generation work. This project only generates and loads the data --
the load-generating harness itself is separate, later work.

It talks to ClickHouse directly via `ch_driver` (no Ecto), against the same
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
