defmodule ClickhouseAdapterEcto.MixProject do
  use Mix.Project

  @version "0.3.0"
  # clickhouse_adapter_ecto is a sibling project inside the
  # clickhouse_adapter_elixir repo -- see ch_driver/mix.exs for the same
  # convention.
  @source_url "https://github.com/mfeckie/clickhouse_adapter_elixir"

  def project do
    [
      app: :clickhouse_adapter_ecto,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "An Ecto adapter for ClickHouse that speaks its native TCP protocol.",
      package: package()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
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
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      # An optional dependency declared only by ch_driver (its own NIF's
      # force-build fallback) isn't fetched/compiled as part of *this*
      # umbrella build unless something in this project's own deps list
      # also names it -- needed for CI's `FORCE_COMPILE=1 mix
      # rustler_precompiled.download` checksum-generation step (see
      # clickhouse_adapter_ecto_ci.yml), which forces a local Rust build of
      # ch_driver's NIF for the runner's own target.
      {:rustler, ">= 0.0.0", optional: true},
      ch_driver_dep()
    ]
  end

  # clickhouse_adapter_ecto depends on ch_driver. Locally (the common case --
  # see RELEASING.md) both live in this monorepo, so a `path:` dep gives fast
  # iteration without needing to publish ch_driver on every change. A package
  # published to Hex, though, cannot depend on another package via `path:` --
  # every dependency must itself be Hex-resolvable. So when *this* package is
  # being built/published for Hex (CI's release workflow sets
  # HEX_PUBLISH=true, see .github/workflows/clickhouse_adapter_ecto_release.yml),
  # swap to a real Hex version constraint instead. See RELEASING.md for the
  # publish order this constraint implies (ch_driver must publish first).
  defp ch_driver_dep do
    if System.get_env("HEX_PUBLISH") in ["1", "true"] do
      {:ch_driver, "~> 0.1"}
    else
      {:ch_driver, path: "../ch_driver"}
    end
  end
end
