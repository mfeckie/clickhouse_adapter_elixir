defmodule Ecto.Adapters.ClickHouse.Migration do
  @moduledoc """
  Validated builders for ClickHouse-specific migration column types that
  have no direct `Ecto.Migration.add/3` equivalent.

  `Ecto.Migration.add/3` validates its `type` argument itself, before this
  adapter's `Ecto.Adapters.ClickHouse.Connection.execute_ddl/1` ever sees
  it, and that validation unconditionally rejects any module implementing
  `Ecto.Type`/`Ecto.ParameterizedType`: passing
  `Ecto.Adapters.ClickHouse.Types.FixedString` directly as a migration
  column type raises `ArgumentError` with "Types defined through Ecto.Type
  or Ecto.ParameterizedType aren't allowed, use their underlying types
  instead", before `change/0` finishes running, let alone before any SQL
  is generated. So a real parameterized-type *module* can never be the
  migration-facing spelling for a ClickHouse column type, no matter how
  it's implemented -- the only shapes `add/3` accepts are atoms, quoted
  atoms, composite tuples, and `references(...)`.

  These functions are the next best thing: instead of hand-typing the
  quoted-atom escape hatch (`add(:code, :"FixedString(16)")`) and hoping
  the string inside is well-formed, call the matching builder here and let
  it validate the parameter and build the quoted atom for you:

      add(:code, ClickHouse.Migration.fixed_string(16))
      add(:status, ClickHouse.Migration.low_cardinality(:string))

  Both still produce exactly the same quoted-atom value the escape hatch
  always accepted (see `Ecto.Adapters.ClickHouse.Connection.column_type!/1`)
  -- there's no other legal way to hand `add/3` a ClickHouse-specific type
  string -- but the parameter is checked here instead of only surfacing as
  a cryptic ClickHouse DDL error at migration time.

  `FixedString(N)` also has a full `Ecto.Adapters.ClickHouse.Types.FixedString`
  `Ecto.ParameterizedType` for the *schema* side (`field :code,
  Ecto.Adapters.ClickHouse.Types.FixedString, size: 16`), where `add/3`'s
  restriction above doesn't apply -- that's the primary reason it gets a
  full ParameterizedType at all, since a bare parameterized type alone
  can't reach migration DDL. `LowCardinality(T)` does not get one: it's
  fully transparent to callers (`ChDriver.Protocol.NativeBlock` decodes it
  to the exact same Elixir value `T` would decode to on its own -- see the
  `## DDL` section of `Ecto.Adapters.ClickHouse.Connection`), so a plain
  `field :status, :string` (or whatever `T` maps to) already behaves
  correctly with no dedicated type; `low_cardinality/1` below exists purely
  to validate and build the migration-side type string.

  `Map(K, V)` has neither a `ParameterizedType` nor a builder here and
  stays on the raw quoted-atom escape hatch
  (`add(:m, :"Map(String, UInt32)")`) -- unlike `FixedString(N)`'s single
  integer parameter or `LowCardinality(T)`'s single inner type,
  `Map(K, V)` has two independent type parameters, and ClickHouse further
  restricts which types `K` may be (a fixed set of scalar types --
  `String`, the integer types, `FixedString`, `UUID`, `LowCardinality(String)`,
  `Date`/`DateTime`, and `Enum`) while `V` accepts nearly any type
  including nested `Array`/`Map`. Building a builder that actually
  enforces that key restriction (rather than silently accepting an
  eventual ClickHouse-side type error) is real, ClickHouse-specific
  validation logic disproportionate to how rarely a migration author
  reaches for `Map(K, V)` directly on a column versus modeling the same
  data as a normal table -- revisit if a concrete use case needs it.
  """

  alias Ecto.Adapters.ClickHouse.Connection

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
  `Ecto.Adapters.ClickHouse.Connection.column_type!/1` already knows how to
  map to a ClickHouse column type (e.g. `:string`, `:integer`, `:uuid`,
  `{:array, :string}`).

      add(:status, Ecto.Adapters.ClickHouse.Migration.low_cardinality(:string))

  Raises `ArgumentError` (via `column_type!/1`) if `inner_type` isn't a
  type this adapter's migration DDL knows how to map.
  """
  @spec low_cardinality(term()) :: atom()
  def low_cardinality(inner_type) do
    :"LowCardinality(#{Connection.column_type!(inner_type)})"
  end
end
