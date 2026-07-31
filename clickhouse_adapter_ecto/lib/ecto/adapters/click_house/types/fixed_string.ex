defmodule Ecto.Adapters.ClickHouse.Types.FixedString do
  @moduledoc """
  An `Ecto.ParameterizedType` for ClickHouse's `FixedString(N)` column type.

  Use it in a schema like any other parameterized type:

      schema "widgets" do
        field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16
      end

  `size` (a positive integer, the `N` in `FixedString(N)`) is required and
  validated when the schema module compiles, not on the first cast.

  ## Value semantics

  `FixedString(N)` always occupies exactly `N` bytes on the wire.
  ClickHouse zero-pads a shorter value up to `N` on insert, and rejects a
  value longer than `N` bytes with `DB::Exception` code 131 ("Too large
  string for FixedString column"). A `SELECT` returns those `N` bytes
  verbatim, padding included -- ClickHouse doesn't strip it back out, and
  neither does this type.

  `cast/2` rejects a binary longer than `size`, but doesn't pad a shorter
  one itself (ClickHouse's own `INSERT` already does that). `load/3`
  returns the padded bytes exactly as decoded -- if you store binary data
  whose natural encoding ends in zero bytes, those bytes are preserved
  rather than trimmed.
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
