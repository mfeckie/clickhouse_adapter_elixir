defmodule Ecto.Adapters.ClickHouse.StorageTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse

  describe "create_database_sql/2" do
    test "is a plain CREATE DATABASE by default" do
      assert ClickHouse.create_database_sql("my_app", []) == ~s[CREATE DATABASE "my_app"]
    end

    test "adds IF NOT EXISTS, ON CLUSTER and ENGINE for a replicated cluster" do
      # IF NOT EXISTS lets a re-run create the database on replicas an
      # earlier, partial run missed.
      assert ClickHouse.create_database_sql("my_app",
               cluster: "{cluster}",
               database_engine: "Replicated"
             ) ==
               ~s[CREATE DATABASE IF NOT EXISTS "my_app" ON CLUSTER '{cluster}' ENGINE = Replicated]
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

    test "rejects an empty engine or cluster" do
      assert_raise ArgumentError, ~r/:database_engine must be a non-empty string/, fn ->
        ClickHouse.create_database_sql("my_app", database_engine: "")
      end

      assert_raise ArgumentError, ~r/:cluster must be a non-empty string/, fn ->
        ClickHouse.create_database_sql("my_app", cluster: "")
      end
    end

    test "rejects a cluster name that would break out of the literal" do
      assert_raise ArgumentError, ~r/bad :cluster "x' ENGINE/, fn ->
        ClickHouse.create_database_sql("my_app", cluster: "x' ENGINE = Memory --")
      end
    end
  end

  describe "drop_database_sql/2" do
    test "waits for the drop to finish with SYNC" do
      assert ClickHouse.drop_database_sql("my_app", []) == ~s[DROP DATABASE "my_app" SYNC]
    end

    test "adds IF EXISTS and ON CLUSTER when a cluster is set" do
      assert ClickHouse.drop_database_sql("my_app", cluster: "{cluster}") ==
               ~s[DROP DATABASE IF EXISTS "my_app" ON CLUSTER '{cluster}' SYNC]
    end
  end

  describe "storage_query_opts/1" do
    test "is empty without a cluster" do
      assert ClickHouse.storage_query_opts([]) == []
    end

    test "bounds ON CLUSTER waits server-side and gives the client a little longer" do
      assert ClickHouse.storage_query_opts(cluster: "{cluster}") == [
               settings: [{"distributed_ddl_task_timeout", "60"}],
               timeout: 70_000
             ]

      assert ClickHouse.storage_query_opts(cluster: "{cluster}", cluster_ddl_timeout: 1_500) == [
               settings: [{"distributed_ddl_task_timeout", "2"}],
               timeout: 11_500
             ]
    end

    test "rejects a non-positive timeout" do
      assert_raise ArgumentError, ~r/:cluster_ddl_timeout/, fn ->
        ClickHouse.storage_query_opts(cluster: "{cluster}", cluster_ddl_timeout: 0)
      end
    end
  end

  describe "default_table_engine/2" do
    alias Ecto.Migration.Table

    test "fills the engine of a table that sets neither engine nor ENGINE in options" do
      assert %Table{engine: "ReplicatedMergeTree"} =
               ClickHouse.default_table_engine(%Table{name: :t}, "ReplicatedMergeTree")

      assert %Table{engine: "ReplicatedMergeTree"} =
               ClickHouse.default_table_engine(
                 %Table{name: :t, options: "ORDER BY id"},
                 "ReplicatedMergeTree"
               )
    end

    test "leaves an explicit engine alone" do
      assert %Table{engine: "Memory"} =
               ClickHouse.default_table_engine(
                 %Table{name: :t, engine: "Memory"},
                 "ReplicatedMergeTree"
               )

      table = %Table{name: :t, options: "ENGINE = Memory"}
      assert ClickHouse.default_table_engine(table, "ReplicatedMergeTree") == table
    end

    test "does nothing without a default" do
      assert ClickHouse.default_table_engine(%Table{name: :t}, nil) == %Table{name: :t}
    end
  end
end
