defmodule Stress.MixProject do
  use Mix.Project

  # stress is a sibling project inside the clickhouse_adapter_elixir repo,
  # same monorepo convention as ch_driver/mix.exs and
  # clickhouse_adapter_ecto/mix.exs -- except this one is a private, never-
  # published in-repo tool (no `package` function below) for seeding a
  # synthetic reporting dataset into the docker-compose ClickHouse instance
  # ahead of later stress-test/load-generation work. It talks to ch_driver
  # directly rather than through clickhouse_adapter_ecto/Ecto: bulk-seeding
  # millions of rows is just batched raw inserts, which don't need a schema
  # layer or query builder on top.
  def project do
    [
      app: :stress,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # An optional dependency declared only by ch_driver (its own NIF's
      # force-build fallback) isn't fetched/compiled as part of this
      # project's own build unless something here also names it -- same
      # reasoning as clickhouse_adapter_ecto/mix.exs's own `:rustler` dep.
      {:rustler, ">= 0.0.0", optional: true},
      {:ch_driver, path: "../ch_driver"},
      # The load-generation harness (mix stress.load) drives real
      # Ecto.Repo/Ecto.Query traffic against the seeded dataset, not raw
      # ch_driver queries -- it exercises the adapter's connection pool the
      # way an actual application would. `ecto`/`ecto_sql` are declared
      # directly (not just pulled in transitively via
      # clickhouse_adapter_ecto) because Mix deps aren't transitively
      # "usable" the way a library's own modules are -- `use Ecto.Repo`/
      # `use Ecto.Schema`/`import Ecto.Query` need these compiled into
      # *this* project, same reasoning as clickhouse_adapter_ecto/mix.exs's
      # own `ecto`/`ecto_sql` deps.
      {:ecto, "~> 3.0"},
      {:ecto_sql, "~> 3.0"},
      {:clickhouse_adapter_ecto, path: "../clickhouse_adapter_ecto"}
    ]
  end
end
