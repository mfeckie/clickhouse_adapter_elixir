defmodule Ecto.Adapters.ClickHouse.MaterializedViewMigrationTest do
  @moduledoc """
  End-to-end integration test against a live ClickHouse (+ Kafka, for the
  Kafka-engine scenario) pair (see `clickhouse_adapter_ecto/docker-compose.yml`)
  for `Ecto.Adapters.ClickHouse.Migration.create_materialized_view/2`.

  Reimplements two shapes of migration roster commonly writes by hand as
  raw `execute/1` SQL, using `create table(...)` (column-type/TTL/ALIAS
  builders from earlier phases) plus `create_materialized_view/2`:

    * a plain MergeTree source table -> materialized view -> target table
      with a different `ORDER BY` (roster's `assignments` /
      `assignments_by_teacher` pattern) -- insert into the source, assert
      the row lands in the target via the MV.
    * a Kafka-engine source table -> materialized view -> target table
      (roster's `kafka_assignments_student_*` pattern) -- produce a
      message onto a live Kafka topic and assert it lands in the target
      table via the MV, polling with a timeout since consumption is
      async.

  Also confirms (per this issue's acceptance criteria) that
  `drop_if_exists(table(:mv_name))` correctly tears down a materialized
  view -- no dedicated `drop_materialized_view` helper is needed.

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

    tables = ~w(
      assignments_by_teacher_mv assignments_by_teacher assignments
      kafka_assignments_student_mv kafka_assignments_student_target kafka_assignments_student_queue
      schema_migrations
    )

    drop_all = fn conn ->
      for t <- tables, do: ChDriver.query(conn, "DROP TABLE IF EXISTS #{t}")
    end

    drop_all.(ddl_conn)

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      drop_all.(conn)
    end)

    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 2
      )

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

  test "MergeTree source -> MV -> target chain (assignments / assignments_by_teacher pattern)",
       %{ddl_conn: ddl_conn} do
    name = Module.concat(__MODULE__, "MergeTreeMigration#{System.unique_integer([:positive])}")

    contents =
      quote do
        use Ecto.Migration

        def up do
          create table(:assignments,
                   primary_key: false,
                   options:
                     Ecto.Adapters.ClickHouse.Migration.table_options(
                       engine: "MergeTree",
                       order_by: "id"
                     )
                 ) do
            add(:id, :id, primary_key: true)
            add(:teacher_id, :integer)
            add(:title, :string)
          end

          create table(:assignments_by_teacher,
                   primary_key: false,
                   options:
                     Ecto.Adapters.ClickHouse.Migration.table_options(
                       engine: "MergeTree",
                       order_by: "(\"teacher_id\", \"id\")"
                     )
                 ) do
            add(:id, :id, primary_key: true)
            add(:teacher_id, :integer, null: false)
            add(:title, :string)
          end

          execute(
            Ecto.Adapters.ClickHouse.Migration.create_materialized_view(
              :assignments_by_teacher_mv,
              to: :assignments_by_teacher,
              as: "SELECT id, teacher_id, title FROM assignments"
            )
          )
        end

        def down do
          drop_if_exists(table(:assignments_by_teacher_mv))
          drop_if_exists(table(:assignments_by_teacher))
          drop_if_exists(table(:assignments))
        end
      end

    Module.create(name, contents, Macro.Env.location(__ENV__))
    migration_module = name
    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    {:ok, %{rows: mv_rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'assignments_by_teacher_mv'"
      )

    assert mv_rows == [["MaterializedView"]]

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "INSERT INTO assignments (id, teacher_id, title) VALUES (1, 42, 'Essay 1')"
      )

    assert {:ok, [[1, 42, "Essay 1"]]} =
             eventually(
               fn ->
                 {:ok, %{rows: rows}} =
                   ChDriver.query(
                     ddl_conn,
                     "SELECT id, teacher_id, title FROM assignments_by_teacher ORDER BY id"
                   )

                 if rows == [[1, 42, "Essay 1"]], do: {:ok, rows}, else: :error
               end,
               10,
               200
             )

    # Confirm the emitted DDL matches the shape create_materialized_view/2
    # is documented to produce -- correctly-ordered TO/AS with the target
    # table name and the exact raw SELECT body passed through unchanged.
    {:ok, %{rows: [[create_sql]]}} =
      ChDriver.query(
        ddl_conn,
        "SELECT create_table_query FROM system.tables WHERE database = currentDatabase() AND name = 'assignments_by_teacher_mv'"
      )

    assert create_sql =~ "TO "
    assert create_sql =~ "assignments_by_teacher"
    assert create_sql =~ "AS SELECT id, teacher_id, title FROM"
    assert String.ends_with?(String.trim(create_sql), "assignments")

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    for table <- ~w(assignments assignments_by_teacher assignments_by_teacher_mv) do
      {:ok, %{rows: rows}} =
        ChDriver.query(
          ddl_conn,
          "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = '#{table}'"
        )

      assert rows == [],
             "expected table #{table} to be dropped after down/0 (drop_if_exists on a MV works)"
    end
  end

  test "Kafka-engine source -> MV -> target chain (kafka_assignments_student_* pattern)",
       %{ddl_conn: ddl_conn, kafka_container: kafka_container} do
    topic = "kafka_assignments_student_topic_#{System.unique_integer([:positive])}"
    group = "kafka_assignments_student_consumer_#{System.unique_integer([:positive])}"
    broker = @kafka_broker

    create_topic(kafka_container, topic)

    name = Module.concat(__MODULE__, "KafkaMigration#{System.unique_integer([:positive])}")

    contents =
      quote do
        use Ecto.Migration

        def up do
          create table(:kafka_assignments_student_target,
                   primary_key: false,
                   options:
                     Ecto.Adapters.ClickHouse.Migration.table_options(
                       engine: "MergeTree",
                       order_by: "id"
                     )
                 ) do
            add(:id, :id, primary_key: true)
            add(:student_id, :integer)
            add(:status, :string)
          end

          create table(:kafka_assignments_student_queue,
                   primary_key: false,
                   options:
                     Ecto.Adapters.ClickHouse.Migration.table_options(
                       engine: "Kafka",
                       settings: [
                         kafka_broker_list: unquote(broker),
                         kafka_topic_list: unquote(topic),
                         kafka_group_name: unquote(group),
                         kafka_format: "JSONEachRow"
                       ]
                     )
                 ) do
            add(:id, :integer)
            add(:student_id, :integer)
            add(:status, :string)
          end

          execute(
            Ecto.Adapters.ClickHouse.Migration.create_materialized_view(
              :kafka_assignments_student_mv,
              to: :kafka_assignments_student_target,
              as: "SELECT id, student_id, status FROM kafka_assignments_student_queue"
            )
          )
        end

        def down do
          drop_if_exists(table(:kafka_assignments_student_mv))
          drop_if_exists(table(:kafka_assignments_student_queue))
          drop_if_exists(table(:kafka_assignments_student_target))
        end
      end

    Module.create(name, contents, Macro.Env.location(__ENV__))
    migration_module = name
    version = System.unique_integer([:positive, :monotonic])

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :up,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    for table <- ~w(kafka_assignments_student_target kafka_assignments_student_queue) do
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
        "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'kafka_assignments_student_mv'"
      )

    assert mv_rows == [["MaterializedView"]]

    produce_message(kafka_container, topic, ~s({"id":7,"student_id":99,"status":"submitted"}))

    assert {:ok, [[7, 99, "submitted"]]} =
             eventually(fn ->
               {:ok, %{rows: rows}} =
                 ChDriver.query(
                   ddl_conn,
                   "SELECT id, student_id, status FROM kafka_assignments_student_target ORDER BY id"
                 )

               if rows == [[7, 99, "submitted"]], do: {:ok, rows}, else: :error
             end)

    assert [^version] =
             Ecto.Migrator.run(TestRepo, [{version, migration_module}], :down,
               all: true,
               log: false,
               log_migrator_sql: false
             )

    for table <-
          ~w(kafka_assignments_student_target kafka_assignments_student_queue kafka_assignments_student_mv) do
      {:ok, %{rows: rows}} =
        ChDriver.query(
          ddl_conn,
          "SELECT 1 FROM system.tables WHERE database = currentDatabase() AND name = '#{table}'"
        )

      assert rows == [], "expected table #{table} to be dropped after down/0"
    end

    assert {:ok, []} =
             eventually(
               fn ->
                 {:ok, %{rows: consumer_rows}} =
                   ChDriver.query(
                     ddl_conn,
                     "SELECT is_currently_used FROM system.kafka_consumers WHERE table = 'kafka_assignments_student_queue'"
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
end
