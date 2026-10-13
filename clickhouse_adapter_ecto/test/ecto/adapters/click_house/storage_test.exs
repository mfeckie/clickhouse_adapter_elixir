defmodule Ecto.Adapters.ClickHouse.StorageTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse

  describe "create_database_sql/2" do
    test "is a plain CREATE DATABASE by default" do
      assert ClickHouse.create_database_sql("my_app", []) == ~s[CREATE DATABASE "my_app"]
    end

    test "adds ON CLUSTER and ENGINE for a replicated cluster" do
      assert ClickHouse.create_database_sql("my_app",
               cluster: "{cluster}",
               database_engine: "Replicated"
             ) ==
               ~s[CREATE DATABASE "my_app" ON CLUSTER '{cluster}' ENGINE = Replicated]
    end

    test "passes an engine with arguments through as given" do
      assert ClickHouse.create_database_sql("my_app",
               database_engine: "Replicated('/clickhouse/my_app', '{shard}', '{replica}')"
             ) ==
               ~s[CREATE DATABASE "my_app" ENGINE = Replicated('/clickhouse/my_app', '{shard}', '{replica}')]
    end

    test "rejects a non-string engine or cluster" do
      assert_raise ArgumentError, ~r/:database_engine/, fn ->
        ClickHouse.create_database_sql("my_app", database_engine: :replicated)
      end

      assert_raise ArgumentError, ~r/:cluster/, fn ->
        ClickHouse.create_database_sql("my_app", cluster: :main)
      end
    end

    test "rejects a cluster name that would break out of the literal" do
      assert_raise ArgumentError, fn ->
        ClickHouse.create_database_sql("my_app", cluster: "x' ENGINE = Memory --")
      end
    end
  end

  describe "drop_database_sql/2" do
    test "adds ON CLUSTER when a cluster is set" do
      assert ClickHouse.drop_database_sql("my_app", []) == ~s[DROP DATABASE "my_app"]

      assert ClickHouse.drop_database_sql("my_app", cluster: "{cluster}") ==
               ~s[DROP DATABASE "my_app" ON CLUSTER '{cluster}']
    end
  end
end
