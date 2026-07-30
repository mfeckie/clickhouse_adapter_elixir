defmodule ChDriver.MixProject do
  use Mix.Project

  def project do
    [
      app: :ch_driver,
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
      {:ch_native, path: "../ch_native"},
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
end
