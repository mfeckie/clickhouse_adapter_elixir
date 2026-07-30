defmodule ClickhouseAdapterElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :clickhouse_adapter_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.0"},
      {:ecto_sql, "~> 3.0"},
      {:ch_driver, path: "../ch_driver"}
    ]
  end
end
