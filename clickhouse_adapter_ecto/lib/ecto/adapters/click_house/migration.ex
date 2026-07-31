defmodule Ecto.Adapters.ClickHouse.Migration do
  @moduledoc """
  Validated builders for ClickHouse-specific migration column types that
  have no direct `Ecto.Migration.add/3` equivalent.

  `Ecto.Migration.add/3` rejects any `Ecto.Type`/`Ecto.ParameterizedType`
  module as a column type, so a type like
  `Ecto.Adapters.ClickHouse.Types.FixedString` can never be given to it
  directly -- only atoms, quoted atoms, composite tuples, and
  `references(...)` are accepted. These builders produce the quoted-atom
  form `add/3` does accept, with the parameter validated up front instead
  of only surfacing as a ClickHouse DDL error at migration time:

      add(:code, Ecto.Adapters.ClickHouse.Migration.fixed_string(16))
      add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))

  `FixedString(N)` additionally has a full `Ecto.ParameterizedType` --
  `Ecto.Adapters.ClickHouse.Types.FixedString` -- for the schema side,
  where `add/3`'s restriction doesn't apply:

      field :code, Ecto.Adapters.ClickHouse.Types.FixedString, size: 16

  `LowCardinality(T)` doesn't get one: it's transparent to callers
  (decoded to the same Elixir value `T` would decode to on its own), so a
  plain `field :status, :string` already works. `Map(K, V)` gets neither
  a builder nor a `ParameterizedType` -- use the quoted atom directly:

      add(:m, :"Map(String, UInt32)")
  """

  alias Ecto.Adapters.ClickHouse.DDL

  @doc """
  Builds the quoted-atom migration type for `FixedString(size)`.

      add(:code, Ecto.Adapters.ClickHouse.Migration.fixed_string(16))

  Raises `ArgumentError` if `size` is not a positive integer.
  """
  @spec fixed_string(pos_integer()) :: atom()
  def fixed_string(size) when is_integer(size) and size > 0 do
    :"FixedString(#{size})"
  end

  def fixed_string(size) do
    raise ArgumentError, "fixed_string/1 expects a positive integer, got: #{inspect(size)}"
  end

  @doc """
  Builds the quoted-atom migration type for `LowCardinality(inner_type)`,
  where `inner_type` is any Ecto type
  `Ecto.Adapters.ClickHouse.DDL`'s `column_type!/1` already knows how to
  map to a ClickHouse column type (e.g. `:string`, `:integer`, `:uuid`,
  `{:array, :string}`).

      add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))

  Raises `ArgumentError` (via `column_type!/1`) if `inner_type` isn't a
  type this adapter's migration DDL knows how to map.
  """
  @spec low_cardinality(term()) :: atom()
  def low_cardinality(inner_type) do
    :"LowCardinality(#{DDL.column_type!(inner_type)})"
  end
end
