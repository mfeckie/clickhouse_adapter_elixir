defmodule Ecto.Adapters.ClickHouse.Types.FixedString do
  @moduledoc """
  An `Ecto.ParameterizedType` for ClickHouse's `FixedString(N)` column type.

  Use it in a schema the same way as any other parameterized type:

      schema "widgets" do
        field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16
      end

  `size` (a positive integer, the `N` in `FixedString(N)`) is required and
  validated at `init/1` time -- i.e. as soon as the schema module compiles,
  not the first time a value is cast.

  ## Value semantics

  `FixedString(N)` always occupies exactly `N` bytes on the wire: ClickHouse
  zero-pads a shorter value up to `N` on `INSERT` and rejects (raises
  `DB::Exception` code 131, "Too large string for FixedString column") a
  value longer than `N` bytes. `SELECT` returns those `N` bytes verbatim,
  padding included -- ClickHouse does not strip it back out.

  This type mirrors that on both sides instead of silently reinterpreting
  it: `cast/2` rejects (with a changeset-friendly `{:error, ...}`) a binary
  longer than `size`, but does not pad a shorter one itself -- ClickHouse's
  own `INSERT` already does that, so padding here too would just be
  duplicated, easy-to-drift logic. `load/3` returns the padded bytes exactly
  as decoded (matching `ChDriver.Protocol.NativeBlock`'s own decision to
  decode `FixedString(N)` to the raw `N`-byte binary rather than trimming
  it) -- trimming trailing `0x00` bytes here would silently discard real
  wire content for any caller intentionally storing binary data whose
  natural encoding ends in zero bytes.
  """

  use Ecto.ParameterizedType

  @impl true
  def init(opts) do
    size = Keyword.fetch!(opts, :size)

    unless is_integer(size) and size > 0 do
      raise ArgumentError,
            "Ecto.Adapters.ClickHouse.Types.FixedString requires a positive integer :size, " <>
              "got: #{inspect(size)}"
    end

    %{size: size}
  end

  @impl true
  def type(_params), do: :string

  @impl true
  def cast(nil, _params), do: {:ok, nil}

  def cast(data, %{size: size}) when is_binary(data) and byte_size(data) <= size do
    {:ok, data}
  end

  def cast(data, %{size: size}) when is_binary(data) do
    {:error, message: "should be at most #{size} byte(s) to fit FixedString(#{size})"}
  end

  def cast(_data, _params), do: :error

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}
  def load(data, _loader, _params) when is_binary(data), do: {:ok, data}
  def load(_data, _loader, _params), do: :error

  @impl true
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(data, _dumper, %{size: size}) when is_binary(data) and byte_size(data) <= size do
    {:ok, data}
  end

  def dump(_data, _dumper, _params), do: :error

  @impl true
  def format(%{size: size}), do: "#Ecto.Adapters.ClickHouse.Types.FixedString<size: #{size}>"
end
