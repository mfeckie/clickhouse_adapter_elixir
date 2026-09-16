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

    test "renders ttl" do
      assert Migration.table_options(
               engine: "ReplacingMergeTree(timestamp)",
               order_by: "(id)",
               ttl: "timestamp + toIntervalYear(2)"
             ) ==
               "ENGINE = ReplacingMergeTree(timestamp) ORDER BY (id) TTL timestamp + toIntervalYear(2)"
    end

    test "renders ttl before settings, matching ClickHouse's own clause order" do
      assert Migration.table_options(
               engine: "MergeTree",
               order_by: "id",
               ttl: "inserted_at + toIntervalMonth(1)",
               settings: [index_granularity: 8192]
             ) ==
               "ENGINE = MergeTree ORDER BY id TTL inserted_at + toIntervalMonth(1) SETTINGS index_granularity = 8192"
    end

    test "raises when :ttl is not a non-empty string" do
      assert_raise ArgumentError, ~r/"TTL" clause must be a non-empty string/, fn ->
        Migration.table_options(engine: "MergeTree", ttl: "")
      end

      assert_raise ArgumentError, ~r/"TTL" clause must be a non-empty string/, fn ->
        Migration.table_options(engine: "MergeTree", ttl: :not_a_string)
      end
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
