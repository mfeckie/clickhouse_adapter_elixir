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
      {:ch_driver, path: "../ch_driver"}
    ]
  end
end
