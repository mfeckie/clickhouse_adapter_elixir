defmodule Ecto.Adapters.ClickHouse.MigrationTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse.Migration

  doctest Migration

  describe "table_options/1" do
    test "renders just the engine when nothing else is given" do
      assert Migration.table_options(engine: "MergeTree") == "ENGINE = MergeTree"
    end

    test "renders order_by" do
      assert Migration.table_options(engine: "MergeTree", order_by: "id") ==
               "ENGINE = MergeTree ORDER BY id"
    end

    test "renders partition_by" do
      assert Migration.table_options(engine: "MergeTree", partition_by: "toYYYYMM(inserted_at)") ==
               "ENGINE = MergeTree PARTITION BY toYYYYMM(inserted_at)"
    end

    test "renders partition_by before order_by, matching ClickHouse's own clause order" do
      assert Migration.table_options(
               engine: "MergeTree",
               order_by: "id",
               partition_by: "toYYYYMM(inserted_at)"
             ) ==
               "ENGINE = MergeTree PARTITION BY toYYYYMM(inserted_at) ORDER BY id"
    end

    test "renders settings with string values single-quoted" do
      assert Migration.table_options(
               engine: "Kafka",
               settings: [kafka_topic_list: "events", kafka_format: "JSONEachRow"]
             ) ==
               "ENGINE = Kafka SETTINGS kafka_topic_list = 'events', kafka_format = 'JSONEachRow'"
    end

    test "renders settings with numeric/boolean values unquoted" do
      assert Migration.table_options(
               engine: "MergeTree",
               settings: [index_granularity: 8192, allow_nullable_key: true]
             ) ==
               "ENGINE = MergeTree SETTINGS index_granularity = 8192, allow_nullable_key = true"
    end

    test "escapes single quotes in string setting values" do
      assert Migration.table_options(
               engine: "MergeTree",
               settings: [comment: "it's fine"]
             ) ==
               "ENGINE = MergeTree SETTINGS comment = 'it''s fine'"
    end

    test "renders engine, partition_by, order_by, and settings together in ClickHouse's clause order" do
      assert Migration.table_options(
               engine: "MergeTree",
               partition_by: "toYYYYMM(inserted_at)",
               order_by: "id",
               settings: [index_granularity: 8192]
             ) ==
               "ENGINE = MergeTree PARTITION BY toYYYYMM(inserted_at) ORDER BY id SETTINGS index_granularity = 8192"
    end

    test "interpolates {:system, var} settings values from the environment at call time" do
      System.put_env("CH_MIGRATION_TEST_BROKER_LIST", "kafka:9092")

      on_exit(fn -> System.delete_env("CH_MIGRATION_TEST_BROKER_LIST") end)

      assert Migration.table_options(
               engine: "Kafka",
               settings: [kafka_broker_list: {:system, "CH_MIGRATION_TEST_BROKER_LIST"}]
             ) ==
               "ENGINE = Kafka SETTINGS kafka_broker_list = 'kafka:9092'"
    end

    test "raises a clear error when a required {:system, var} env var is missing" do
      System.delete_env("CH_MIGRATION_TEST_MISSING_VAR")

      assert_raise ArgumentError, ~r/CH_MIGRATION_TEST_MISSING_VAR.*is not set/s, fn ->
        Migration.table_options(
          engine: "Kafka",
          settings: [kafka_broker_list: {:system, "CH_MIGRATION_TEST_MISSING_VAR"}]
        )
      end
    end

    test "raises when :engine is missing" do
      assert_raise ArgumentError, ~r/requires an :engine/, fn ->
        Migration.table_options(order_by: "id")
      end
    end

    test "raises when :engine is not a non-empty string" do
      assert_raise ArgumentError, ~r/:engine must be a non-empty string/, fn ->
        Migration.table_options(engine: "")
      end

      assert_raise ArgumentError, ~r/:engine must be a non-empty string/, fn ->
        Migration.table_options(engine: :MergeTree)
      end
    end

    test "raises on an unrecognized top-level option key" do
      assert_raise ArgumentError, ~r/unknown option\(s\).*sample_by/, fn ->
        Migration.table_options(engine: "MergeTree", sample_by: "id")
      end
    end

    test "raises when :settings is not a keyword list" do
      assert_raise ArgumentError, ~r/:settings must be a keyword list/, fn ->
        Migration.table_options(engine: "MergeTree", settings: ["not", "a", "keyword", "list"])
      end
    end

    test "raises on a setting value of an unsupported type" do
      assert_raise ArgumentError, ~r/unsupported value/, fn ->
        Migration.table_options(engine: "MergeTree", settings: [weird: %{a: 1}])
      end
    end

    test "raises when given a non-keyword-list argument" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        Migration.table_options("ENGINE = MergeTree")
      end
    end
  end

  describe "enum8/1" do
    test "builds the Enum8 quoted-atom type from a keyword list" do
      assert Migration.enum8(unknown: 0, active: 1) == :"Enum8('unknown' = 0, 'active' = 1)"
    end

    test "accepts string keys" do
      assert Migration.enum8([{"unknown", 0}, {"active", 1}]) ==
               :"Enum8('unknown' = 0, 'active' = 1)"
    end

    test "raises on an empty list" do
      assert_raise ArgumentError, ~r/non-empty list/, fn -> Migration.enum8([]) end
    end

    test "raises when not given a list" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        Migration.enum8("not a list")
      end
    end

    test "raises on a non-integer value" do
      assert_raise ArgumentError, ~r/must be an integer/, fn ->
        Migration.enum8(unknown: "0")
      end
    end

    test "raises on a non-atom/string key" do
      assert_raise ArgumentError, ~r/expects a list of \{key, value\} pairs/, fn ->
        Migration.enum8([{1, 0}])
      end
    end

    test "raises on duplicate keys" do
      assert_raise ArgumentError, ~r/duplicate key/, fn ->
        Migration.enum8([{:unknown, 0}, {"unknown", 1}])
      end
    end

    test "raises on duplicate values" do
      assert_raise ArgumentError, ~r/duplicate value/, fn ->
        Migration.enum8(unknown: 0, active: 0)
      end
    end

    test "escapes a single quote in a key instead of breaking out of the string literal" do
      assert Migration.enum8([{"o'clock", 0}]) == :"Enum8('o''clock' = 0)"
    end

    test "escaping a key containing a single quote doesn't corrupt the rendered DDL" do
      assert Migration.enum8([{"'; DROP TABLE users; --", 0}, {"active", 1}]) ==
               :"Enum8('''; DROP TABLE users; --' = 0, 'active' = 1)"
    end
  end

  describe "tuple/1" do
    test "builds a named Tuple quoted-atom type from a keyword list" do
      assert Migration.tuple(x: :float, y: :float) == :"Tuple(x Float64, y Float64)"
    end

    test "accepts string field names" do
      assert Migration.tuple([{"a", :integer}]) == :"Tuple(a Int32)"
    end

    test "supports nesting via another builder's output as a field type" do
      inner = Migration.tuple(label: :string, correct: :boolean)

      assert Migration.tuple(id: :integer, options: {:array, inner}) ==
               :"Tuple(id Int32, options Array(Tuple(label String, correct UInt8)))"
    end

    test "is usable as the inner type of Ecto's {:array, inner_type} shorthand" do
      alias Ecto.Adapters.ClickHouse.DDL

      assert DDL.column_type!({:array, Migration.tuple(a: :integer, b: :string)}) ==
               "Array(Tuple(a Int32, b String))"
    end

    test "raises on an empty list" do
      assert_raise ArgumentError, ~r/non-empty list/, fn -> Migration.tuple([]) end
    end

    test "raises when not given a list" do
      assert_raise ArgumentError, ~r/expects a keyword list/, fn ->
        Migration.tuple("not a list")
      end
    end

    test "raises on an invalid field name" do
      assert_raise ArgumentError, ~r/not a valid identifier/, fn ->
        Migration.tuple([{"1bad", :string}])
      end
    end

    test "raises (via column_type!/1) on an unknown field type" do
      assert_raise ArgumentError, ~r/does not know how to map/, fn ->
        Migration.tuple(a: :not_a_real_type)
      end
    end
  end

  describe "variant/1" do
    test "builds a Variant quoted-atom type from a list of types" do
      assert Migration.variant([:integer, :string, :boolean]) ==
               :"Variant(Int32, String, UInt8)"
    end

    test "raises when fewer than 2 types are given" do
      assert_raise ArgumentError, ~r/at least 2 types/, fn ->
        Migration.variant([:integer])
      end
    end

    test "raises when not given a list" do
      assert_raise ArgumentError, ~r/expects a list of types/, fn ->
        Migration.variant(:integer)
      end
    end

    test "raises (via column_type!/1) on an unknown type" do
      assert_raise ArgumentError, ~r/does not know how to map/, fn ->
        Migration.variant([:integer, :not_a_real_type])
      end
    end
  end

  describe "aggregate_function/2" do
    test "builds an AggregateFunction quoted-atom type" do
      assert Migration.aggregate_function("uniqExact", :uuid) ==
               :"AggregateFunction(uniqExact, UUID)"
    end

    test "accepts an atom function name" do
      assert Migration.aggregate_function(:max, :integer) == :"AggregateFunction(max, Int32)"
    end

    test "raises on an invalid function name" do
      assert_raise ArgumentError, ~r/valid function name/, fn ->
        Migration.aggregate_function("not valid!", :integer)
      end
    end

    test "raises (via column_type!/1) on an unknown type" do
      assert_raise ArgumentError, ~r/does not know how to map/, fn ->
        Migration.aggregate_function("max", :not_a_real_type)
      end
    end
  end

  describe "simple_aggregate_function/2" do
    test "builds a SimpleAggregateFunction quoted-atom type" do
      assert Migration.simple_aggregate_function("sum", :integer) ==
               :"SimpleAggregateFunction(sum, Int32)"
    end

    test "raises on an invalid function name" do
      assert_raise ArgumentError, ~r/valid function name/, fn ->
        Migration.simple_aggregate_function("not valid!", :integer)
      end
    end

    test "raises (via column_type!/1) on an unknown type" do
      assert_raise ArgumentError, ~r/does not know how to map/, fn ->
        Migration.simple_aggregate_function("sum", :not_a_real_type)
      end
    end
  end
end
