defmodule ChDriver.MixProject do
  use Mix.Project

  @version "0.1.0"
  # ch_driver is a sibling project inside the clickhouse_adapter_elixir repo,
  # not its own repo -- see ch_codec/mix.exs for the same convention.
  @source_url "https://github.com/mfeckie/clickhouse_adapter_elixir"

  def project do
    [
      app: :ch_driver,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "DBConnection driver speaking ClickHouse's native TCP protocol.",
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      ch_native_dep(),
      {:db_connection, "~> 2.0"},
      # `Decimal(P, S)` decoding (see `ChDriver.Protocol.NativeBlock`) needs
      # the `Decimal` struct. Constrained to accept either major version
      # since `adapter/` (a sibling app depending on this one via `path:`)
      # already pulls in `decimal ~> 3.0` transitively through `ecto`/
      # `ecto_sql` -- a hard `~> 2.0` here would make that combination
      # unresolvable.
      {:decimal, "~> 2.0 or ~> 3.0"}
    ]
  end

  # ch_driver depends on ch_native. Locally (the common case -- see
  # RELEASING.md) both live in this monorepo, so a `path:` dep gives fast
  # iteration without needing to publish ch_native on every change. A package
  # published to Hex, though, cannot depend on another package via `path:` --
  # every dependency must itself be Hex-resolvable. So when *this* package is
  # being built/published for Hex (CI's release workflow sets
  # HEX_PUBLISH=true, see .github/workflows/ch_driver_release.yml), swap to a
  # real Hex version constraint instead. See RELEASING.md for the publish
  # order this constraint implies (ch_codec, then ch_native, must publish
  # first).
  defp ch_native_dep do
    if System.get_env("HEX_PUBLISH") in ["1", "true"] do
      {:ch_native, "~> 0.1"}
    else
      {:ch_native, path: "../ch_native"}
    end
  end
end
