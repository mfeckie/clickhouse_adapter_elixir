defmodule Ecto.Adapters.ClickHouse.KafkaIngestionTest do
  @moduledoc """
  End-to-end integration test against a live ClickHouse + Kafka pair (see
  `clickhouse_adapter_ecto/docker-compose.yml`): a migration's `up/0`
  creates the three pieces of the Kafka streaming-ingestion pipeline
  (target table, Kafka source table, materialized view) via raw
  `execute/1` SQL, a message produced onto the topic lands in the target
  table through the materialized view, and `down/0` tears everything down
  without orphaning the Kafka consumer group.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  @kafka_broker "kafka:29092"

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  setup do
    # In CI (clickhouse_adapter_ecto_ci.yml) this container is started
    # directly by GitHub Actions' `services:` block, not by docker-compose,
    # so it isn't part of any compose project -- found by published port
    # instead of by name/project.
    kafka_container =
      case System.cmd("docker", ["ps", "-q", "--filter", "publish=9092"], stderr_to_stdout: true) do
        {output, 0} -> output |> String.split("\n", trim: true) |> List.first("")
        {output, status} -> flunk("docker ps --filter publish=9092 failed (#{status}): #{output}")
      end

    if kafka_container == "" do
      flunk(
        "kafka service isn't running -- run `docker compose up -d` from clickhouse_adapter_ecto/ first"
      )
    end

    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS order_events_mv")
      ChDriver.query(conn, "DROP TABLE IF EXISTS order_events_queue")
      ChDriver.query(conn, "DROP TABLE IF EXISTS order_events")
      ChDriver.query(conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn, kafka_container: kafka_container}
  end

  defp produce_message(kafka_container, topic, json) do
    port =
      Port.open({:spawn_executable, System.find_executable("docker")}, [
        :binary,
        :exit_status,
        args: [
          "exec",
          "-i",
          kafka_container,
          "/opt/kafka/bin/kafka-console-producer.sh",
          "--bootstrap-server",
          "localhost:9092",
          "--topic",
          topic
        ]
      ])

    Port.command(port, json <> "\n")
    Port.close(port)
    :ok
  end

  defp create_topic(kafka_container, topic) do
    System.cmd("docker", [
      "exec",
      kafka_container,
      "/opt/kafka/bin/kafka-topics.sh",
      "--bootstrap-server",
      "localhost:9092",
      "--create",
      "--if-not-exists",
      "--topic",
      topic,
      "--partitions",
      "1",
      "--replication-factor",
      "1"
    ])
  end

  defp delete_topic(kafka_container, topic) do
    System.cmd("docker", [
      "exec",
      kafka_container,
      "/opt/kafka/bin/kafka-topics.sh",
      "--bootstrap-server",
      "localhost:9092",
      "--delete",
      "--topic",
      topic
    ])
  end

  defp eventually(fun, attempts \\ 20, sleep_ms \\ 500) do
    Enum.reduce_while(1..attempts, nil, fn attempt, _acc ->
      case fun.() do
        {:ok, result} -> {:halt, {:ok, result}}
        :error when attempt == attempts -> {:halt, :error}
        :error -> Process.sleep(sleep_ms) && {:cont, nil}
      end
    end)
  end

  test "a migration creates the target table, Kafka table and materialized view; a produced message lands in the target table; down tears everything down cleanly",
       %{ddl_conn: ddl_conn, kafka_container: kafka_container} do
    topic = "order_events_topic_#{System.unique_integer([:positive])}"
    group = "order_events_consumer_#{System.unique_integer([:positive])}"

    create_topic(kafka_container, topic)

    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS order_events_mv")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS order_events_queue")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS order_events")
    ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

    version = System.unique_integer([:positive, :monotonic])

    up_sql = fn ->
      [
        "CREATE TABLE order_events (id UInt64, status String) ENGINE = MergeTree ORDER BY id",
        """
        CREATE TABLE order_events_queue (id UInt64, status String)
        ENGINE = Kafka
        SETTINGS kafka_broker_list = '#{@kafka_broker}',
                 kafka_topic_list = '#{topic}',
                 kafka_group_name = '#{group}',
                 kafka_format = 'JSONEachRow'
        """,
        "CREATE MATERIALIZED VIEW order_events_mv TO order_events AS SELECT id, status FROM order_events_queue"
      ]
    end

    down_sql = [
      "DROP TABLE IF EXISTS order_events_mv",
      "DROP TABLE IF EXISTS order_events_queue",
      "DROP TABLE IF EXISTS order_events"
    ]

    migration_module = build_migration_module(up_sql.(), down_sql)

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    for table <- ~w(order_events order_events_queue) do
      {:ok, %{rows: rows}} =
        ChDriver.query(
          ddl_conn,
          "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = '#{table}'"
        )

      assert rows == [[1]], "expected table #{table} to exist after up/0"
    end

    {:ok, %{rows: mv_rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'order_events_mv'"
      )

    assert mv_rows == [["MaterializedView"]]

    produce_message(kafka_container, topic, ~s({"id":1,"status":"shipped"}))

    assert {:ok, [[1, "shipped"]]} =
             eventually(fn ->
               {:ok, %{rows: rows}} =
                 ChDriver.query(ddl_conn, "SELECT id, status FROM order_events ORDER BY id")

               if rows == [[1, "shipped"]], do: {:ok, rows}, else: :error
             end)

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    for table <- ~w(order_events order_events_queue order_events_mv) do
      {:ok, %{rows: rows}} =
        ChDriver.query(
          ddl_conn,
          "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = '#{table}'"
        )

      assert rows == [], "expected table #{table} to be dropped after down/0"
    end

    # "orphaned" here means what this adapter's migrations can actually
    # cause: a ClickHouse-side consumer still attached and polling for a
    # topic/group nothing references anymore. `is_currently_used` is
    # ClickHouse's own bookkeeping for that, updated as soon as its consumer
    # thread stops -- unlike the Kafka broker's own consumer-group-member
    # record, which can take up to the client's session timeout (tens of
    # seconds) to reflect a graceful leave, regardless of whether
    # ClickHouse's side already cleanly stopped.
    assert {:ok, []} =
             eventually(
               fn ->
                 {:ok, %{rows: consumer_rows}} =
                   ChDriver.query(
                     ddl_conn,
                     "SELECT is_currently_used FROM system.kafka_consumers WHERE table = 'order_events_queue'"
                   )

                 if consumer_rows == [] or consumer_rows == [[0]],
                   do: {:ok, []},
                   else: :error
               end,
               10,
               200
             )

    delete_topic(kafka_container, topic)
  end

  defp build_migration_module(up_statements, down_statements) do
    name = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

    contents =
      quote do
        use Ecto.Migration

        def up do
          for sql <- unquote(up_statements), do: execute(sql)
        end

        def down do
          for sql <- unquote(down_statements), do: execute(sql)
        end
      end

    Module.create(name, contents, Macro.Env.location(__ENV__))
    name
  end
end
