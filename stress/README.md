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
