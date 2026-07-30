defmodule ChCodec.MixProject do
  use Mix.Project

  @version "0.1.0"
  # TODO: replace with this project's actual GitHub repo once one exists —
  # RustlerPrecompiled.base_url (lib/ch_codec/native.ex) derives its release
  # download URL from package.links["GitHub"].
  @source_url "https://github.com/CHANGEME/ch_codec"

  def project do
    [
      app: :ch_codec,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "LZ4 block + CityHash v1.0.3 codec NIF for ClickHouse's native protocol.",
      package: package()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib native/chcodec_native/src native/chcodec_native/Cargo.toml
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
      {:rustler, "~> 0.36", optional: true}
    ]
  end
end
