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

  `enum8/1`, `tuple/1`, `variant/1`, `aggregate_function/2`, and
  `simple_aggregate_function/2` follow the same pattern -- validated
  builders that return the quoted-atom form `add/3` accepts:

      add(:status, Ecto.Adapters.ClickHouse.Migration.enum8(unknown: 0, active: 1, archived: 2))

      add(:point, Ecto.Adapters.ClickHouse.Migration.tuple(x: :float, y: :float))

      # nesting: a Tuple field whose type is itself Array(Tuple(...)).
      add(
        :answers,
        Ecto.Adapters.ClickHouse.Migration.tuple(
          id: :integer,
          options: {:array, Ecto.Adapters.ClickHouse.Migration.tuple(label: :string, correct: :boolean)}
        )
      )

      add(:mixed, Ecto.Adapters.ClickHouse.Migration.variant([:integer, :string, :boolean]))

      add(:visitors, Ecto.Adapters.ClickHouse.Migration.aggregate_function("uniqExact", :uuid))

      add(:total, Ecto.Adapters.ClickHouse.Migration.simple_aggregate_function("sum", :integer))

  ## Building a table's `options:` string

  `table/2`'s `options:` takes a single raw string for everything after the
  column list -- engine, `ORDER BY`, `PARTITION BY`, `SETTINGS k = v, ...`.
  `table_options/1` builds that string from a keyword list instead of
  requiring migration authors to hand-interpolate and quote it (`SETTINGS`
  in particular gets tedious once it accumulates several key/value pairs):

      create table(:events, primary_key: false,
        options: Ecto.Adapters.ClickHouse.Migration.table_options(
          engine: "MergeTree",
          partition_by: "toYYYYMM(inserted_at)",
          order_by: "id"
        )
      ) do
        add :id, :id, primary_key: true
        add :inserted_at, :utc_datetime
      end

  It also resolves `{:system, "ENV_VAR"}` settings values from the
  environment at the time the helper runs (migration-run time, i.e.
  `mix ecto.migrate`, not compile time) -- handy for credentials that
  shouldn't be committed as a literal string in a migration file, like the
  Kafka-engine example in `Ecto.Adapters.ClickHouse.DDL`'s moduledoc:

      execute(\"\"\"
      CREATE TABLE events_queue (id UInt64, payload String)
      \#{Ecto.Adapters.ClickHouse.Migration.table_options(
        engine: "Kafka",
        settings: [
          kafka_broker_list: {:system, "KAFKA_BROKER_LIST"},
          kafka_topic_list: "events",
          kafka_group_name: "events_consumer",
          kafka_format: "JSONEachRow"
        ]
      )}
      \"\"\")

  which renders (given `KAFKA_BROKER_LIST=kafka:9092` in the environment
  the migration runs in) as:

      ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092', kafka_topic_list = 'events', kafka_group_name = 'events_consumer', kafka_format = 'JSONEachRow'
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

  @doc """
  Builds the quoted-atom migration type for `Enum8('key' = value, ...)`.

  `values` is a keyword list (or list of `{key, value}` pairs, `key` an
  atom or a string) mapping each enum key to its integer value.

      add(:status, Ecto.Adapters.ClickHouse.Migration.enum8(unknown: 0, active: 1, archived: 2))
      #=> add(:status, :"Enum8('unknown' = 0, 'active' = 1, 'archived' = 2)")

      iex> Ecto.Adapters.ClickHouse.Migration.enum8(unknown: 0, active: 1)
      :"Enum8('unknown' = 0, 'active' = 1)"

  Raises `ArgumentError` if `values` isn't a non-empty list of
  `{key, value}` pairs, if a key isn't an atom or string, if a value isn't
  an integer, or if there are duplicate keys or duplicate values.
  """
  @spec enum8([{atom() | String.t(), integer()}]) :: atom()
  def enum8(values) when is_list(values) and values != [] do
    Enum.each(values, &validate_enum_pair!/1)
    validate_enum_no_duplicate_keys!(values)
    validate_enum_no_duplicate_values!(values)

    rendered =
      Enum.map_intersperse(values, ", ", fn {key, value} ->
        "'#{quote_enum_key(key)}' = #{value}"
      end)

    :"Enum8(#{IO.iodata_to_binary(rendered)})"
  end

  def enum8([]) do
    raise ArgumentError, "enum8/1 expects a non-empty list of {key, value} pairs, got: []"
  end

  def enum8(other) do
    raise ArgumentError,
          "enum8/1 expects a keyword list (or list of {key, value} pairs), got: #{inspect(other)}"
  end

  # Enum keys are embedded inside a single-quoted ClickHouse string literal
  # in the rendered type -- a literal `'` in the key would otherwise close
  # the quote early and let the rest of the key corrupt the DDL, so it's
  # escaped by doubling, same as `quote_setting_string/1` does for
  # `table_options/1`'s `:settings` values.
  defp quote_enum_key(key) do
    key |> to_string() |> String.replace("'", "''")
  end

  defp validate_enum_pair!({key, value}) when is_atom(key) or is_binary(key) do
    unless is_integer(value) do
      raise ArgumentError,
            "enum8/1 value for key #{inspect(key)} must be an integer, got: #{inspect(value)}"
    end
  end

  defp validate_enum_pair!(other) do
    raise ArgumentError,
          "enum8/1 expects a list of {key, value} pairs with an atom/string key and an " <>
            "integer value, got: #{inspect(other)}"
  end

  defp validate_enum_no_duplicate_keys!(values) do
    keys = Enum.map(values, fn {key, _value} -> to_string(key) end)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "enum8/1 received duplicate key(s): #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp validate_enum_no_duplicate_values!(values) do
    vals = Enum.map(values, fn {_key, value} -> value end)

    case vals -- Enum.uniq(vals) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "enum8/1 received duplicate value(s): #{inspect(Enum.uniq(duplicates))}"
    end
  end

  @doc """
  Builds the quoted-atom migration type for a named `Tuple(field type, ...)`.

  `fields` is a keyword list (or list of `{name, type}` pairs) mapping
  each tuple field name to an Ecto type
  `Ecto.Adapters.ClickHouse.DDL`'s `column_type!/1` knows how to map
  (a plain type like `:string`, `{:array, :string}`, or the quoted-atom
  output of another builder in this module, including nested calls to
  `tuple/1` itself).

      add(:point, Ecto.Adapters.ClickHouse.Migration.tuple(x: :float, y: :float))
      #=> add(:point, :"Tuple(x Float64, y Float64)")

      iex> Ecto.Adapters.ClickHouse.Migration.tuple(x: :float, y: :float)
      :"Tuple(x Float64, y Float64)"

  Nesting -- a `Tuple` field whose type is itself `Array(Tuple(...))` --
  works by passing another `tuple/1` call (optionally wrapped in
  `{:array, ...}`) as a field's type:

      iex> Ecto.Adapters.ClickHouse.Migration.tuple(
      ...>   id: :integer,
      ...>   options: {:array, Ecto.Adapters.ClickHouse.Migration.tuple(label: :string, correct: :boolean)}
      ...> )
      :"Tuple(id Int32, options Array(Tuple(label String, correct UInt8)))"

  The result is also usable as the inner type of Ecto's own
  `{:array, inner_type}` shorthand, for an `Array(Tuple(...))` column:

      add(:rows, {:array, Ecto.Adapters.ClickHouse.Migration.tuple(a: :integer, b: :string)})
      #=> add(:rows, :"Array(Tuple(a Int32, b String))")

  Raises `ArgumentError` if `fields` isn't a non-empty list of
  `{name, type}` pairs, if a field name isn't a valid identifier
  (atom/string, starting with a letter or underscore), or (via
  `column_type!/1`) if a field's type isn't one this adapter's migration
  DDL knows how to map.
  """
  @spec tuple([{atom() | String.t(), term()}]) :: atom()
  def tuple(fields) when is_list(fields) and fields != [] do
    rendered =
      Enum.map_intersperse(fields, ", ", fn
        {name, type} ->
          "#{validate_field_name!(name)} #{DDL.column_type!(type)}"

        other ->
          raise ArgumentError,
                "tuple/1 expects a list of {field_name, type} pairs, got element: " <>
                  "#{inspect(other)}"
      end)

    :"Tuple(#{IO.iodata_to_binary(rendered)})"
  end

  def tuple([]) do
    raise ArgumentError, "tuple/1 expects a non-empty list of {field_name, type} pairs, got: []"
  end

  def tuple(other) do
    raise ArgumentError,
          "tuple/1 expects a keyword list (or list of {field_name, type} pairs), got: " <>
            "#{inspect(other)}"
  end

  @field_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp validate_field_name!(name) when is_atom(name), do: validate_field_name!(to_string(name))

  defp validate_field_name!(name) when is_binary(name) do
    if Regex.match?(@field_name_pattern, name) do
      name
    else
      raise ArgumentError,
            "tuple/1 field name #{inspect(name)} is not a valid identifier -- must start with " <>
              "a letter or underscore and contain only letters, digits, and underscores"
    end
  end

  defp validate_field_name!(other) do
    raise ArgumentError,
          "tuple/1 field name must be an atom or string, got: #{inspect(other)}"
  end

  @doc """
  Builds the quoted-atom migration type for `Variant(Type1, Type2, ...)`.

  `types` is a list of at least two Ecto types
  `Ecto.Adapters.ClickHouse.DDL`'s `column_type!/1` knows how to map.

      add(:mixed, Ecto.Adapters.ClickHouse.Migration.variant([:integer, :string, :boolean]))
      #=> add(:mixed, :"Variant(Int32, String, UInt8)")

      iex> Ecto.Adapters.ClickHouse.Migration.variant([:integer, :string])
      :"Variant(Int32, String)"

  Raises `ArgumentError` if `types` isn't a list of at least two elements,
  or (via `column_type!/1`) if one of the types isn't one this adapter's
  migration DDL knows how to map.
  """
  @spec variant([term()]) :: atom()
  def variant(types) when is_list(types) and length(types) >= 2 do
    rendered = Enum.map_intersperse(types, ", ", &DDL.column_type!/1)
    :"Variant(#{IO.iodata_to_binary(rendered)})"
  end

  def variant(types) when is_list(types) do
    raise ArgumentError,
          "variant/1 expects a list of at least 2 types, got: #{inspect(types)}"
  end

  def variant(other) do
    raise ArgumentError, "variant/1 expects a list of types, got: #{inspect(other)}"
  end

  @doc """
  Builds the quoted-atom migration type for `AggregateFunction(fn_name, Type)`.

  `fn_name` is the aggregate function's name (e.g. `"uniqExact"`, `"max"`,
  `"any"` -- any valid ClickHouse identifier, not a fixed list), and
  `type` is the single argument type, an Ecto type
  `Ecto.Adapters.ClickHouse.DDL`'s `column_type!/1` knows how to map.

      add(:visitors, Ecto.Adapters.ClickHouse.Migration.aggregate_function("uniqExact", :uuid))
      #=> add(:visitors, :"AggregateFunction(uniqExact, UUID)")

      iex> Ecto.Adapters.ClickHouse.Migration.aggregate_function("max", :integer)
      :"AggregateFunction(max, Int32)"

  Raises `ArgumentError` if `fn_name` isn't a valid identifier-shaped
  atom/string, or (via `column_type!/1`) if `type` isn't one this
  adapter's migration DDL knows how to map.
  """
  @spec aggregate_function(atom() | String.t(), term()) :: atom()
  def aggregate_function(fn_name, type) do
    :"AggregateFunction(#{validate_fn_name!(fn_name)}, #{DDL.column_type!(type)})"
  end

  @doc """
  Builds the quoted-atom migration type for
  `SimpleAggregateFunction(fn_name, Type)`.

  Same shape and validation as `aggregate_function/2`.

      add(:total, Ecto.Adapters.ClickHouse.Migration.simple_aggregate_function("sum", :integer))
      #=> add(:total, :"SimpleAggregateFunction(sum, Int32)")

      iex> Ecto.Adapters.ClickHouse.Migration.simple_aggregate_function("sum", :integer)
      :"SimpleAggregateFunction(sum, Int32)"

  Raises `ArgumentError` if `fn_name` isn't a valid identifier-shaped
  atom/string, or (via `column_type!/1`) if `type` isn't one this
  adapter's migration DDL knows how to map.
  """
  @spec simple_aggregate_function(atom() | String.t(), term()) :: atom()
  def simple_aggregate_function(fn_name, type) do
    :"SimpleAggregateFunction(#{validate_fn_name!(fn_name)}, #{DDL.column_type!(type)})"
  end

  @fn_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp validate_fn_name!(fn_name) when is_atom(fn_name), do: validate_fn_name!(to_string(fn_name))

  defp validate_fn_name!(fn_name) when is_binary(fn_name) do
    if Regex.match?(@fn_name_pattern, fn_name) do
      fn_name
    else
      raise ArgumentError,
            "expected a valid function name (identifier), got: #{inspect(fn_name)}"
    end
  end

  defp validate_fn_name!(other) do
    raise ArgumentError, "expected a function name as an atom or string, got: #{inspect(other)}"
  end

  @typedoc """
  A single `:settings` value for `table_options/1`.

  A plain string is rendered single-quoted (ClickHouse `String`-typed
  settings, e.g. `kafka_broker_list`); a number or boolean is rendered
  unquoted (ClickHouse numeric/boolean-ish settings, e.g.
  `kafka_num_consumers`). `{:system, "ENV_VAR"}` is resolved from the
  environment at call time (migration-run time) via `System.fetch_env!/1`
  and then rendered single-quoted, same as a literal string.
  """
  @type setting_value :: String.t() | number() | boolean() | {:system, String.t()}

  @valid_table_options_keys [:engine, :partition_by, :order_by, :settings]

  @doc """
  Builds the options string `table/2`'s `options:` expects (everything
  after the column list: `ENGINE`, `PARTITION BY`, `ORDER BY`,
  `SETTINGS`), from a keyword list instead of a hand-quoted raw string.

  ## Options

    * `:engine` (required) -- the engine name/clause, e.g. `"MergeTree"`
      or a full engine expression like `"Kafka"`.
    * `:partition_by` -- rendered as `PARTITION BY <value>`.
    * `:order_by` -- rendered as `ORDER BY <value>`.
    * `:settings` -- a keyword list of `key: value` pairs, rendered as
      `SETTINGS key1 = 'value1', key2 = value2, ...`. String values are
      single-quoted; numbers and booleans are not. A value can also be
      `{:system, "ENV_VAR"}` to interpolate an environment variable
      resolved when the migration runs -- see the moduledoc's Kafka
      example.

  Clause order in the rendered string (`ENGINE` · `PARTITION BY` ·
  `ORDER BY` · `SETTINGS`) matches ClickHouse's own `CREATE TABLE` clause
  order; only clauses that were given are included.

      iex> Ecto.Adapters.ClickHouse.Migration.table_options(engine: "MergeTree", order_by: "id")
      "ENGINE = MergeTree ORDER BY id"

      iex> Ecto.Adapters.ClickHouse.Migration.table_options(
      ...>   engine: "MergeTree",
      ...>   partition_by: "toYYYYMM(inserted_at)",
      ...>   order_by: "id",
      ...>   settings: [index_granularity: 8192]
      ...> )
      "ENGINE = MergeTree PARTITION BY toYYYYMM(inserted_at) ORDER BY id SETTINGS index_granularity = 8192"

  Raises `ArgumentError` if `:engine` is missing, if an unrecognized
  top-level option key is given, if `:settings` isn't a keyword list, if
  a setting's value isn't a string/number/boolean/`{:system, _}`, or if a
  `{:system, "ENV_VAR"}` setting's environment variable isn't set.
  """
  @spec table_options(keyword()) :: String.t()
  def table_options(opts) when is_list(opts) do
    validate_table_options_keys!(opts)
    engine = fetch_engine!(opts)

    [
      "ENGINE = #{engine}",
      optional_clause("PARTITION BY", Keyword.get(opts, :partition_by)),
      optional_clause("ORDER BY", Keyword.get(opts, :order_by)),
      settings_clause(Keyword.get(opts, :settings))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def table_options(other) do
    raise ArgumentError, "table_options/1 expects a keyword list, got: #{inspect(other)}"
  end

  defp validate_table_options_keys!(opts) do
    case Keyword.keys(opts) -- @valid_table_options_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "table_options/1 received unknown option(s) #{inspect(unknown)} -- " <>
                "supported keys are #{inspect(@valid_table_options_keys)}"
    end
  end

  defp fetch_engine!(opts) do
    case Keyword.fetch(opts, :engine) do
      {:ok, engine} when is_binary(engine) and engine != "" ->
        engine

      {:ok, other} ->
        raise ArgumentError,
              "table_options/1 :engine must be a non-empty string, got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "table_options/1 requires an :engine (e.g. " <>
                "table_options(engine: \"MergeTree\", ...)) -- every ClickHouse table needs " <>
                "an ENGINE"
    end
  end

  defp optional_clause(_prefix, nil), do: nil

  defp optional_clause(prefix, value) when is_binary(value) and value != "" do
    "#{prefix} #{value}"
  end

  defp optional_clause(prefix, other) do
    raise ArgumentError,
          "table_options/1 #{inspect(prefix)} clause must be a non-empty string, got: " <>
            "#{inspect(other)}"
  end

  defp settings_clause(nil), do: nil
  defp settings_clause([]), do: nil

  defp settings_clause(settings) when is_list(settings) do
    unless Keyword.keyword?(settings) do
      raise ArgumentError,
            "table_options/1 :settings must be a keyword list of key: value pairs, got: " <>
              "#{inspect(settings)}"
    end

    rendered =
      Enum.map_intersperse(settings, ", ", fn {key, value} ->
        "#{key} = #{render_setting_value!(key, value)}"
      end)

    IO.iodata_to_binary(["SETTINGS " | rendered])
  end

  defp settings_clause(other) do
    raise ArgumentError,
          "table_options/1 :settings must be a keyword list of key: value pairs, got: " <>
            "#{inspect(other)}"
  end

  defp render_setting_value!(_key, {:system, var}) when is_binary(var) do
    case System.fetch_env(var) do
      {:ok, value} ->
        quote_setting_string(value)

      :error ->
        raise ArgumentError,
              "table_options/1 setting references environment variable #{inspect(var)} via " <>
                "{:system, #{inspect(var)}}, but it is not set -- set it before running this " <>
                "migration (e.g. `export #{var}=...`)"
    end
  end

  defp render_setting_value!(_key, value) when is_binary(value), do: quote_setting_string(value)

  defp render_setting_value!(_key, value) when is_integer(value) or is_float(value) do
    to_string(value)
  end

  defp render_setting_value!(_key, value) when is_boolean(value), do: to_string(value)

  defp render_setting_value!(key, other) do
    raise ArgumentError,
          "table_options/1 setting #{inspect(key)} has an unsupported value #{inspect(other)} " <>
            "-- expected a string, number, boolean, or {:system, \"ENV_VAR\"}"
  end

  defp quote_setting_string(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end
end
