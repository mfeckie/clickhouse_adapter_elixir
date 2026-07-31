defmodule ChNative.MixProject do
  use Mix.Project

  @version "0.1.0"
  # ch_native is a sibling project inside the clickhouse_adapter_elixir repo,
  # not its own repo -- see ch_codec/mix.exs for the same convention.
  @source_url "https://github.com/mfeckie/clickhouse_adapter_elixir"

  def project do
    [
      app: :ch_native,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Native ClickHouse block/column encoding built on ch_codec's LZ4 + CityHash NIF.",
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
      ch_codec_dep()
    ]
  end

  # ch_native depends on ch_codec. Locally (the common case -- see
  # RELEASING.md) both live in this monorepo, so a `path:` dep gives fast
  # iteration without needing to publish ch_codec on every change. A package
  # published to Hex, though, cannot depend on another package via `path:` --
  # every dependency must itself be Hex-resolvable. So when *this* package is
  # being built/published for Hex (CI's release workflow sets
  # HEX_PUBLISH=true, see .github/workflows/ch_native_release.yml), swap to a
  # real Hex version constraint instead. See RELEASING.md for the publish
  # order this constraint implies (ch_codec must publish first).
  defp ch_codec_dep do
    if System.get_env("HEX_PUBLISH") in ["1", "true"] do
      {:ch_codec, "~> 0.1"}
    else
      {:ch_codec, path: "../ch_codec"}
    end
  end
end
