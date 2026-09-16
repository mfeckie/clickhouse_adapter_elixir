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

  describe "create_materialized_view/2" do
    test "emits CREATE MATERIALIZED VIEW IF NOT EXISTS ... TO ... AS ..." do
      assert Migration.create_materialized_view(:events_mv,
               to: :events,
               as: "SELECT id, payload FROM events_queue"
             ) ==
               ~s(CREATE MATERIALIZED VIEW IF NOT EXISTS "events_mv" TO "events" AS SELECT id, payload FROM events_queue)
    end

    test "accepts string name and target" do
      assert Migration.create_materialized_view("events_mv",
               to: "events",
               as: "SELECT id FROM events_queue"
             ) ==
               ~s(CREATE MATERIALIZED VIEW IF NOT EXISTS "events_mv" TO "events" AS SELECT id FROM events_queue)
    end

    test "quotes identifiers, not the raw SQL body" do
      assert Migration.create_materialized_view(:my_mv,
               to: :my_target,
               as: "SELECT * FROM src WHERE x = 'literal'"
             ) ==
               ~s(CREATE MATERIALIZED VIEW IF NOT EXISTS "my_mv" TO "my_target" AS SELECT * FROM src WHERE x = 'literal')
    end

    test "raises ArgumentError when :to is missing" do
      assert_raise ArgumentError, ~r/requires :to/, fn ->
        Migration.create_materialized_view(:events_mv, as: "SELECT 1")
      end
    end

    test "raises ArgumentError when :as is missing" do
      assert_raise ArgumentError, ~r/requires :as/, fn ->
        Migration.create_materialized_view(:events_mv, to: :events)
      end
    end

    test "raises ArgumentError when :to is not an atom or string" do
      assert_raise ArgumentError, ~r/:to must be an atom or string/, fn ->
        Migration.create_materialized_view(:events_mv, to: 123, as: "SELECT 1")
      end
    end

    test "raises ArgumentError when :as is not a non-empty string" do
      assert_raise ArgumentError, ~r/:as must be a non-empty raw SQL string/, fn ->
        Migration.create_materialized_view(:events_mv, to: :events, as: "")
      end

      assert_raise ArgumentError, ~r/:as must be a non-empty raw SQL string/, fn ->
        Migration.create_materialized_view(:events_mv, to: :events, as: 123)
      end
    end

    test "raises ArgumentError when the view name itself is invalid" do
      assert_raise ArgumentError, ~r/name must be an atom or string/, fn ->
        Migration.create_materialized_view(123, to: :events, as: "SELECT 1")
      end
    end

    test "raises ArgumentError when given a non-keyword-list argument" do
      assert_raise ArgumentError, ~r/expects a keyword list of options/, fn ->
        Migration.create_materialized_view(:events_mv, "TO events AS SELECT 1")
      end
    end

    test "raises ArgumentError (via Naming.quote_table/2) when the name contains a double quote" do
      assert_raise ArgumentError, ~r/bad table name/, fn ->
        Migration.create_materialized_view(~s(bad"name), to: :events, as: "SELECT 1")
      end
    end
  end

  describe "create_view/2" do
    test "emits CREATE VIEW IF NOT EXISTS ... AS ..." do
      assert Migration.create_view(:active_users_view,
               as: "SELECT id FROM users WHERE active = 1"
             ) ==
               ~s(CREATE VIEW IF NOT EXISTS "active_users_view" AS SELECT id FROM users WHERE active = 1)
    end

    test "accepts a string name" do
      assert Migration.create_view("active_users_view", as: "SELECT 1") ==
               ~s(CREATE VIEW IF NOT EXISTS "active_users_view" AS SELECT 1)
    end

    test "raises ArgumentError when :as is missing" do
      assert_raise ArgumentError, ~r/requires :as/, fn ->
        Migration.create_view(:active_users_view, [])
      end
    end

    test "raises ArgumentError when :as is not a non-empty string" do
      assert_raise ArgumentError, ~r/:as must be a non-empty raw SQL string/, fn ->
        Migration.create_view(:active_users_view, as: "")
      end
    end

    test "raises ArgumentError when the view name itself is invalid" do
      assert_raise ArgumentError, ~r/name must be an atom or string/, fn ->
        Migration.create_view(%{}, as: "SELECT 1")
      end
    end

    test "raises ArgumentError when given a non-keyword-list argument" do
      assert_raise ArgumentError, ~r/expects a keyword list of options/, fn ->
        Migration.create_view(:active_users_view, "AS SELECT 1")
      end
    end
  end
end
