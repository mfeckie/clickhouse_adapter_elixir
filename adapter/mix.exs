defmodule ClickhouseAdapterElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :clickhouse_adapter_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # `test/support` holds test-only helper modules (currently
  # `Ecto.Adapters.ClickHouse.TestCase`, see its moduledoc) that aren't
  # `*_test.exs` files themselves, so `mix test` won't compile them unless
  # they're on the compile path -- this is the same convention Phoenix
  # generators use for `test/support/`.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.0"},
      {:ecto_sql, "~> 3.0"},
      {:ch_driver, path: "../ch_driver"}
    ]
  end
end
