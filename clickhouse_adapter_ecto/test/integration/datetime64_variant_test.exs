defmodule Ecto.Adapters.ClickHouse.DateTime64VariantIntegrationTest do
  @moduledoc """
  End-to-end integration coverage for the two types that used to raise
  `{:unsupported_type, ...}` at query time, exercised through the *Ecto*
  layer (`Repo.insert!/1` / `Repo.all/1`) rather than raw `ChDriver.query`:

    * `DateTime64(P)` — reachable from ordinary Ecto migrations, since
      `:utc_datetime_usec` / `:naive_datetime_usec` already generate
      `DateTime64(6)` DDL (see
      `Ecto.Adapters.ClickHouse.Connection.column_type!/1`). That means
      *every* microsecond-precision timestamp field was affected, not just
      hand-written raw types, which is what made this worth fixing at this
      layer too. Also covered as a verbatim raw type
      (`add(:t_ms, :"DateTime64(3)")`) paired with `:utc_datetime_usec`.

    * `Map(String, Variant(Bool, Int32, String))` — a heterogeneous
      "details" bag, given verbatim as a quoted atom in the migration
      (the `LowCardinality(String)` pattern from
      `extended_types_test.exs`) and paired with Ecto's built-in `:map`
      schema type. This is the exact shape from the original report.

      Note the *read* path is what was broken and is what this covers.
      A heterogeneous map cannot be *bound* as a query parameter at all:
      it would need a `Map(String, Variant(...))` parameter type, and
      ClickHouse refuses to parse a `Variant`-valued Map from parameter
      text ("Unsupported types to CAST AS Map"), so
      `ChDriver.Params.type/1` raises a clear `ArgumentError` for it
      rather than letting the server fail confusingly. These rows are
      therefore written with a literal INSERT and read back through Ecto,
      which is the realistic shape for this type anyway (such a column is
      typically populated by an ingestion pipeline, not by
      `Repo.insert!/1`).

  `ch_driver/test/ch_driver/datetime64_test.exs` and
  `variant_test.exs` cover the wire-level decoding thoroughly; this file is
  specifically about the types surviving the trip through Ecto's
  loaders/dumpers and a real schema.

  Requires `docker compose up -d` (from `clickhouse_adapter_ecto/`) to have
  been run first.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_ecto, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule CreateEvents do
    use Ecto.Migration

    def change do
      create table(:dt64_variant_events,
               primary_key: false,
               options: "ENGINE = MergeTree ORDER BY id"
             ) do
        add(:id, :id, primary_key: true)
        # :utc_datetime_usec maps to DateTime64(6) through the adapter's
        # own column_type!/1 -- no raw type needed.
        add(:started_at, :utc_datetime_usec, null: false)
        # A verbatim millisecond-precision DateTime64, to prove a
        # precision other than the adapter's default 6 also round-trips.
        add(:t_ms, :"DateTime64(3)", null: false)
        add(:details, :"Map(String, Variant(Bool, Int32, String))", null: false)
      end
    end
  end

  defmodule Event do
    use Ecto.Schema

    @primary_key false
    schema "dt64_variant_events" do
      field(:id, :integer)
      field(:started_at, :utc_datetime_usec)
      field(:t_ms, :utc_datetime_usec)
      field(:details, :map)
    end
  end

  setup_all do
    {:ok, _pid} =
      TestRepo.start_link(
        hostname: "localhost",
        port: 9000,
        database: "default",
        username: "default",
        password: "",
        pool_size: 5,
        settings: [{"enable_variant_type", "1"}]
      )

    {:ok, ddl_conn} =
      ChDriver.start_link(
        hostname: "localhost",
        port: 9000,
        settings: [{"enable_variant_type", "1"}]
      )

    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS dt64_variant_events")
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS schema_migrations")

    version = System.unique_integer([:positive, :monotonic])

    [^version] =
      Ecto.Migrator.run(TestRepo, [{version, CreateEvents}], :up,
        all: true,
        log: false,
        log_migrator_sql: false
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS dt64_variant_events")
      ChDriver.query(conn, "DROP TABLE IF EXISTS schema_migrations")
    end)

    %{ddl_conn: ddl_conn}
  end

  setup %{ddl_conn: ddl_conn} do
    {:ok, _} = ChDriver.query(ddl_conn, "TRUNCATE TABLE dt64_variant_events")
    :ok
  end

  test "the migration generates the expected DateTime64/Variant column types", %{
    ddl_conn: ddl_conn
  } do
    {:ok, %{rows: rows}} =
      ChDriver.query(
        ddl_conn,
        "SELECT name, type FROM system.columns " <>
          "WHERE database = currentDatabase() AND table = 'dt64_variant_events' " <>
          "ORDER BY name"
      )

    assert rows == [
             ["details", "Map(String, Variant(Bool, Int32, String))"],
             ["id", "UInt64"],
             ["started_at", "DateTime64(6)"],
             ["t_ms", "DateTime64(3)"]
           ]
  end

  test "DateTime64 fields round-trip through Repo.insert!/1 and Repo.all/1" do
    started_at = DateTime.new!(~D[2024-03-15], ~T[12:34:56.789789], "Etc/UTC")
    # The column is DateTime64(3), but Ecto's :utc_datetime_usec type
    # requires a microsecond-precision struct on the Elixir side, so bind
    # microseconds and expect ClickHouse to store the millisecond truncation.
    t_ms = DateTime.new!(~D[2024-03-15], ~T[12:34:56.789000], "Etc/UTC")

    # `details` is homogeneous here so it can be bound as a parameter; the
    # heterogeneous Variant case is covered by the next test, which writes
    # it via a literal INSERT (see this module's moduledoc for why it
    # can't be bound).
    TestRepo.insert!(%Event{
      id: 1,
      started_at: started_at,
      t_ms: t_ms,
      details: %{"name" => "widget"}
    })

    TestRepo.insert!(%Event{
      id: 2,
      started_at: DateTime.from_unix!(0, :microsecond),
      t_ms: DateTime.from_unix!(0, :microsecond),
      details: %{}
    })

    assert [event1, event2] = Event |> order_by([e], asc: e.id) |> TestRepo.all()

    assert event1.id == 1
    assert DateTime.compare(event1.started_at, started_at) == :eq
    assert event1.started_at.microsecond == {789_789, 6}
    # t_ms is a DateTime64(3) column, so the driver decodes it with
    # precision 3 -- but the schema field is :utc_datetime_usec, and Ecto's
    # loader for that type normalizes the struct to precision 6. The
    # instant and the digits are unchanged either way; only the reported
    # precision differs. (`ch_driver`'s own
    # test/ch_driver/datetime64_test.exs asserts the precision-3 struct the
    # driver hands back, below this normalization.)
    assert DateTime.compare(event1.t_ms, t_ms) == :eq
    assert event1.t_ms.microsecond == {789_000, 6}
    assert event1.details == %{"name" => "widget"}

    assert event2.id == 2
    assert DateTime.compare(event2.started_at, DateTime.from_unix!(0, :second)) == :eq
    assert event2.details == %{}
  end

  test "a heterogeneous Map(String, Variant(...)) written by a literal INSERT loads through Repo.all/1",
       %{ddl_conn: ddl_conn} do
    # This is the exact failing shape from the original report: the mixed
    # Bool/Int32/String values inside the Variant used to raise
    # {:unsupported_type, "Variant(Bool, Int32, String)"} on SELECT.
    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "INSERT INTO dt64_variant_events (id, started_at, t_ms, details) VALUES " <>
          "(1, '2024-03-15 12:34:56.789789', '2024-03-15 12:34:56.789', " <>
          "{'ok': true, 'count': 42, 'name': 'widget'}), " <>
          "(2, '1970-01-01 00:00:00.000000', '1970-01-01 00:00:00.000', {})"
      )

    assert [event1, event2] = Event |> order_by([e], asc: e.id) |> TestRepo.all()

    assert event1.details == %{"ok" => true, "count" => 42, "name" => "widget"}
    assert event2.details == %{}

    # The DateTime64 columns alongside them decode correctly too (both
    # reported at precision 6 by Ecto's :utc_datetime_usec loader, which
    # normalizes the DateTime64(3) column's precision-3 struct upward --
    # see the previous test).
    assert event1.started_at.microsecond == {789_789, 6}
    assert event1.t_ms.microsecond == {789_000, 6}
  end

  test "a DateTime64 field is usable in a WHERE clause, not just in the select list" do
    started_at = DateTime.new!(~D[2024-03-15], ~T[12:34:56.789789], "Etc/UTC")

    TestRepo.insert!(%Event{
      id: 1,
      started_at: started_at,
      t_ms: started_at,
      details: %{}
    })

    TestRepo.insert!(%Event{
      id: 2,
      started_at: DateTime.new!(~D[2020-01-01], ~T[00:00:00.000000], "Etc/UTC"),
      t_ms: DateTime.new!(~D[2020-01-01], ~T[00:00:00.000000], "Etc/UTC"),
      details: %{}
    })

    cutoff = DateTime.new!(~D[2022-01-01], ~T[00:00:00.000000], "Etc/UTC")

    assert [%Event{id: 1}] =
             Event |> where([e], e.started_at > ^cutoff) |> TestRepo.all()
  end
end
