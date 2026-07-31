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
end
