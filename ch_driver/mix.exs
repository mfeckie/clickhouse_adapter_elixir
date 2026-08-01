defmodule ChDriver.MixProject do
  use Mix.Project

  @version "0.2.0"
  # ch_driver is a sibling project inside the clickhouse_adapter_elixir repo,
  # not its own repo -- see adapter/mix.exs for the same convention.
  @source_url "https://github.com/mfeckie/clickhouse_adapter_elixir"

  def project do
    [
      app: :ch_driver,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "DBConnection driver speaking ClickHouse's native TCP protocol, including its " <>
          "LZ4/CityHash compression NIF and compressed-block wire envelope.",
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib native/ch_driver_native/src native/ch_driver_native/Cargo.toml
                 checksum-*.exs mix.exs README.md)
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
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.36", optional: true},
      {:db_connection, "~> 2.0"},
      # `Decimal(P, S)` decoding (see `ChDriver.Protocol.NativeBlock`) needs
      # the `Decimal` struct. Constrained to accept either major version
      # since `adapter/` (a sibling app depending on this one via `path:`)
      # already pulls in `decimal ~> 3.0` transitively through `ecto`/
      # `ecto_sql` -- a hard `~> 2.0` here would make that combination
      # unresolvable.
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
