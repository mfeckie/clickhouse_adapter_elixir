defmodule ChDriver.Codec.Native do
  @moduledoc false

  mix_config = Mix.Project.config()
  version = mix_config[:version]
  github_url = mix_config[:package][:links]["GitHub"]

  use RustlerPrecompiled,
    otp_app: :ch_driver,
    crate: "ch_driver_native",
    base_url: "#{github_url}/releases/download/ch_driver-v#{version}",
    force_build: System.get_env("FORCE_COMPILE") in ["1", "true"],
    version: version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    )

  def lz4_compress(_data), do: :erlang.nif_error(:nif_not_loaded)
  def lz4_decompress(_data, _uncompressed_size), do: :erlang.nif_error(:nif_not_loaded)
  def cityhash128(_data), do: :erlang.nif_error(:nif_not_loaded)
end
