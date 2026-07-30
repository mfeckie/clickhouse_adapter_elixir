defmodule Ecto.Adapters.ClickHouse.RepoAdvancedIntegrationTest do
  @moduledoc """
  Further end-to-end integration coverage against a *live* ClickHouse
  instance (see `adapter/docker-compose.yml`) for
  clickhouse_adapter_elixir-8a2.14, filling gaps not covered by
  `repo_test.exs`:

    * a more realistic mixed-column-type schema on a `MergeTree` table
      (rather than `Memory`/two-integer-and-a-string), with an explicit
      `ORDER BY` and a filtered/ordered/limited query against it.
    * `Repo.insert_all/3`'s actual behaviour (it does batch multiple rows
      into a single `INSERT ... VALUES (...), (...)` statement, but see the
      documented `num_rows` quirk below).
    * concurrent `Repo` usage through the pool via `Task.async_stream/3`.
    * a ClickHouse-level error (bad SQL syntax, and a value that can't be
      parsed as its column's declared type) surfacing as a raised exception
      at the `Repo.query!/2` call site rather than hanging or crashing
      oddly.
    * a string literal containing a single quote, a backslash, and
      multi-byte unicode round-tripping correctly through the inline-literal
      SQL generation in `Ecto.Adapters.ClickHouse.Connection`.
    * two documented, known gaps: `:boolean` Ecto fields backed by
      ClickHouse's conventional `UInt8` boolean encoding, and `DateTime`
      columns mapped to `:naive_datetime`/`:utc_datetime` Ecto fields, do not
      round-trip through `Repo.all/1` today (see the two dedicated tests
      below for why).

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  # Deliberately excludes the table's `active UInt8` and `recorded_at
  # DateTime` columns -- see `BoolMeasurement`/`TimestampMeasurement` below
  # and their dedicated tests for why selecting those columns back through
  # plain Ecto currently fails.
  defmodule Measurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:label, :string)
      field(:small_count, :integer)
      field(:big_count, :integer)
      field(:ratio, :float)
    end
  end

  # Same table, but also maps the `active UInt8` column to an Ecto
  # `:boolean` field -- used only by the dedicated "known gap" test below.
  defmodule BoolMeasurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:active, :boolean)
    end
  end

  # Same table, but also maps the `recorded_at DateTime` column to an Ecto
  # `:naive_datetime` field -- used only by the dedicated "known gap" test
  # below.
  defmodule TimestampMeasurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:recorded_at, :naive_datetime)
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
        pool_size: 5
      )

    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS measurements")

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        """
        CREATE TABLE measurements (
          id UInt64,
          label String,
          small_count Int16,
          big_count Int64,
          ratio Float64,
          active UInt8,
          recorded_at DateTime
        ) ENGINE = MergeTree ORDER BY id
        """
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS measurements")
    end)

    :ok
  end

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(conn, "TRUNCATE TABLE measurements")
    :ok
  end

  test "a realistic mixed-column-type schema on a MergeTree table round-trips through insert!/all with WHERE/ORDER BY/LIMIT" do
    TestRepo.insert!(%Measurement{
      id: 1,
      label: "alpha",
      small_count: 5,
      big_count: 5_000_000_000,
      ratio: 1.5
    })

    TestRepo.insert!(%Measurement{
      id: 2,
      label: "beta",
      small_count: 10,
      big_count: 10_000_000_000,
      ratio: 2.5
    })

    TestRepo.insert!(%Measurement{
      id: 3,
      label: "gamma",
      small_count: 15,
      big_count: 15_000_000_000,
      ratio: 3.5
    })

    import Ecto.Query

    results =
      Measurement
      |> where([m], m.small_count > 5)
      |> order_by([m], desc: m.id)
      |> limit(2)
      |> TestRepo.all()

    assert [
             %Measurement{id: 3, label: "gamma", small_count: 15, big_count: 15_000_000_000},
             %Measurement{id: 2, label: "beta", small_count: 10, big_count: 10_000_000_000}
           ] = results

    assert Enum.map(results, & &1.ratio) == [3.5, 2.5]
  end

  test "Repo.insert_all/3 batches multiple rows in a single INSERT, but reports num_rows: 0 (a documented ClickHouse-adapter gap)" do
    rows = [
      %{id: 1, label: "a", small_count: 1, big_count: 1, ratio: 1.0},
      %{id: 2, label: "b", small_count: 2, big_count: 2, ratio: 2.0},
      %{id: 3, label: "c", small_count: 3, big_count: 3, ratio: 3.0}
    ]

    # The insert genuinely happens (all 3 rows land, batched into one
    # `INSERT ... VALUES (...), (...), (...)` statement -- confirmed via the
    # row count below) -- but unlike Postgres/MyXQL, ClickHouse's native
    # protocol reports `num_rows: 0` for a successful INSERT (there's no
    # "rows affected" concept), and `Ecto.Adapters.SQL.insert_all/9` doesn't
    # get the same `num_rows: 0`-is-fine override that
    # `Ecto.Adapters.ClickHouse.insert/6` has for the single-row path (see
    # that module's moduledoc). So `Repo.insert_all/3`'s return value is
    # currently unreliable as a "how many rows were inserted" count -- always
    # verify via a follow-up `Repo.all/2`/count query instead of trusting
    # this return value.
    assert {0, []} = TestRepo.insert_all(Measurement, rows)

    assert length(TestRepo.all(Measurement)) == 3
  end

  test "concurrent Repo operations through the pool via Task.async_stream" do
    1..20
    |> Task.async_stream(
      fn i ->
        TestRepo.insert!(%Measurement{
          id: i,
          label: "concurrent-#{i}",
          small_count: i,
          big_count: i,
          ratio: i * 1.0
        })
      end,
      max_concurrency: 10,
      timeout: 10_000
    )
    |> Enum.each(fn {:ok, %Measurement{}} -> :ok end)

    assert length(TestRepo.all(Measurement)) == 20

    import Ecto.Query

    results =
      1..20
      |> Task.async_stream(
        fn i ->
          Measurement
          |> where([m], m.id == ^i)
          |> TestRepo.all()
        end,
        max_concurrency: 10,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, [%Measurement{id: id}]} -> id end)
      |> Enum.sort()

    assert results == Enum.to_list(1..20)
  end

  test "a ClickHouse syntax error surfaces as a raised exception at Repo.query!/2, not a hang or crash" do
    assert_raise ChDriver.Error, fn ->
      TestRepo.query!("SELEKT this is not valid SQL")
    end

    # the pool must still be usable afterwards.
    assert {:ok, %{rows: [[1]]}} = TestRepo.query("SELECT 1")
  end

  test "a value that can't be parsed as its column's declared type surfaces as a raised exception, not a hang or crash" do
    # `small_count` is `Int16`; a non-numeric string can't be parsed as one,
    # and ClickHouse rejects it at insert time with a DB::Exception rather
    # than silently coercing it to e.g. 0 or NULL.
    assert_raise ChDriver.Error, ~r/cannot parse/i, fn ->
      TestRepo.query!(
        "INSERT INTO measurements (id, label, small_count, big_count, ratio, active, recorded_at) " <>
          "VALUES (1, 'x', 'not_a_number', 1, 1.0, 1, '2024-01-01 00:00:00')"
      )
    end

    assert {:ok, %{rows: [[0]]}} = TestRepo.query("SELECT count(*) FROM measurements")
  end

  test "a string literal with a single quote, a backslash, and unicode round-trips correctly" do
    tricky = "it's a \\backslash\\ and some 日本語 and emoji \u{1F600}"

    TestRepo.insert!(%Measurement{
      id: 1,
      label: tricky,
      small_count: 1,
      big_count: 1,
      ratio: 1.0
    })

    assert [%Measurement{label: ^tricky}] = TestRepo.all(Measurement)

    import Ecto.Query

    assert [%Measurement{id: 1}] =
             Measurement |> where([m], m.label == ^tricky) |> TestRepo.all()
  end

  test "known gap: a :boolean Ecto field backed by ClickHouse's UInt8 boolean convention does not round-trip through Repo.all/1" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "INSERT INTO measurements (id, label, small_count, big_count, ratio, active, recorded_at) " <>
          "VALUES (1, 'x', 1, 1, 1.0, 1, '2024-01-01 00:00:00')"
      )

    # ClickHouse hands back the raw integer `1` for a `UInt8` column (there's
    # no native boolean wire type), and this adapter doesn't define a custom
    # `Ecto.Adapter`-level loader to coerce that into `true`/`false` the way
    # e.g. MyXQL does for MySQL's TINYINT-backed booleans -- so Ecto's
    # built-in `:boolean` type rejects it outright at load time. Booleans
    # aren't usable end-to-end through this adapter yet; store/query the
    # raw `0`/`1` as a plain `:integer` field instead until a loader is
    # added.
    assert_raise ArgumentError, ~r/cannot load `1` as type :boolean/, fn ->
      BoolMeasurement |> TestRepo.all()
    end
  end

  test "known gap: a :naive_datetime Ecto field backed by a ClickHouse DateTime column does not round-trip through Repo.all/1" do
    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "INSERT INTO measurements (id, label, small_count, big_count, ratio, active, recorded_at) " <>
          "VALUES (1, 'x', 1, 1, 1.0, 1, '2024-01-01 00:00:00')"
      )

    # Writing a `NaiveDateTime` as an inline SQL literal works fine (see
    # `Connection.encode_literal/1` -- ClickHouse parses the
    # `'YYYY-MM-DD HH:MM:SS'` string literal into its `DateTime` column), but
    # reading it back does not: `ChDriver.Protocol.NativeBlock`'s `DateTime`
    # column codec decodes to the raw little-endian Unix-epoch `UInt32` off
    # the wire (see `column_codec("DateTime")`), and this adapter has no
    # custom loader to turn that integer back into a `NaiveDateTime`/
    # `DateTime` struct -- so Ecto's built-in `:naive_datetime` type rejects
    # the raw epoch integer at load time. `DateTime` columns aren't usable
    # end-to-end through Ecto schemas yet; query them as a plain `:integer`
    # (Unix timestamp) field, or via a raw `ChDriver.query/2`, until a loader
    # is added.
    assert_raise ArgumentError, ~r/cannot load `\d+` as type :naive_datetime/, fn ->
      TimestampMeasurement |> TestRepo.all()
    end
  end
end
