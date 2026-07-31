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
