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
    * `:boolean` Ecto fields backed by ClickHouse's conventional `UInt8`
      boolean encoding, and `DateTime` columns mapped to
      `:naive_datetime`/`:utc_datetime` Ecto fields, round-tripping correctly
      through `Repo.insert!/1`/`Repo.all/1` (clickhouse_adapter_elixir-8a2.18
      -- see the dedicated tests below; this used to be a documented gap
      where both raised `ArgumentError` at load time).

  Requires `docker compose up -d` (from `adapter/`) to have been run first.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  # Deliberately excludes the table's `active UInt8` and `recorded_at
  # DateTime` columns -- see `BoolMeasurement`/`TimestampMeasurement` below,
  # which map those columns to `:boolean`/`:naive_datetime` fields instead.
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
  # `:boolean` field -- used only by the dedicated round-trip test below.
  defmodule BoolMeasurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:active, :boolean)
    end
  end

  # Same table, but also maps the `recorded_at DateTime` column to Ecto
  # `:naive_datetime` and `:utc_datetime` fields -- used only by the
  # dedicated round-trip tests below.
  defmodule TimestampMeasurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:recorded_at, :naive_datetime)
    end
  end

  defmodule UtcTimestampMeasurement do
    use Ecto.Schema

    @primary_key false
    schema "measurements" do
      field(:id, :integer)
      field(:recorded_at, :utc_datetime)
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

    # No `ratio_of_defaults_for_sparse_serialization` override here: a
    # mostly-`0`/default UInt8 column like `active` will legitimately get
    # sparse-encoded on disk once enough default-valued rows accumulate
    # across this file's tests, and `ChDriver.Protocol.NativeBlock` now
    # decodes that correctly (clickhouse_adapter_elixir-8a2.20; see
    # `ChDriver.SparseTest` for dedicated live coverage) -- this table no
    # longer needs to work around it.
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

  test "a literal '?' character in raw SQL text never misaligns bind params" do
    # `Ecto.Adapters.SQL.Connection.query/4`'s `?` placeholders are raw SQL
    # text, not AST-generated -- a naive `String.split(sql, "?")` (the old
    # `inline_params/2` this replaced) would misalign here: the first `?`
    # inside the string literal isn't a bind placeholder at all, so a
    # split-based scan would see 2 placeholders for 1 real param.
    # `bind_params/2` tracks quoted regions instead, so this round-trips.
    assert {:ok, %{rows: [[42, "is this a ? mark?"]]}} =
             TestRepo.query("SELECT ?, 'is this a ? mark?'", [42])

    # And the reverse: a bound *value* containing a literal '?' must reach
    # the server byte-for-byte via the wire parameter, never inlined as SQL
    # text at all.
    assert {:ok, %{rows: [["contains a ? too"]]}} =
             TestRepo.query("SELECT ?", ["contains a ? too"])
  end

  test "a :boolean Ecto field backed by ClickHouse's UInt8 boolean convention round-trips through Repo.insert!/Repo.all" do
    # `Ecto.Adapters.ClickHouse.Connection.encode_literal/1` already writes
    # `true`/`false` as the SQL literals `1`/`0` (ClickHouse has no native
    # boolean wire type; `UInt8` is the idiomatic encoding), so the insert
    # side of this has always worked -- it's reading `true`/`false` back out
    # that used to fail (clickhouse_adapter_elixir-8a2.18): ClickHouse hands
    # back the raw integer `0`/`1` for a `UInt8` column, and
    # `Ecto.Adapters.ClickHouse.loaders/2` now coerces that into `false`/
    # `true` before Ecto's built-in `:boolean` type loader runs (the same
    # pattern MyXQL uses for MySQL's TINYINT-backed booleans).
    TestRepo.insert!(%BoolMeasurement{id: 1, active: true})
    TestRepo.insert!(%BoolMeasurement{id: 2, active: false})

    results = BoolMeasurement |> TestRepo.all() |> Enum.sort_by(& &1.id)

    assert [
             %BoolMeasurement{id: 1, active: true},
             %BoolMeasurement{id: 2, active: false}
           ] = results
  end

  test "a :naive_datetime Ecto field backed by a ClickHouse DateTime column round-trips through Repo.insert!/Repo.all" do
    # ClickHouse's plain `DateTime` only has second-level precision on the
    # wire (a little-endian `UInt32` Unix-epoch second count -- see
    # `ChDriver.Protocol.NativeBlock`'s `decode_datetime/1`); there is no
    # `DateTime64`/microsecond storage involved here. A `NaiveDateTime` with
    # microseconds would silently lose them on the way into ClickHouse (the
    # inline SQL literal ClickHouse parses only has second resolution), so
    # this test deliberately picks a timestamp with `microsecond: {0, 0}` to
    # keep the round-trip lossless and unambiguous. Using
    # `:naive_datetime_usec` against a plain `DateTime` column would truncate
    # microseconds back to `.000000` on load -- use a `DateTime64(N)` column
    # (mapped via `:naive_datetime_usec`'s DDL type, see
    # `Connection.column_type!/1`) if microsecond precision is required.
    naive = ~N[2024-03-15 12:34:56]

    TestRepo.insert!(%TimestampMeasurement{id: 1, recorded_at: naive})

    assert [%TimestampMeasurement{id: 1, recorded_at: ^naive}] =
             TimestampMeasurement |> TestRepo.all()
  end

  test "a :utc_datetime Ecto field backed by a ClickHouse DateTime column round-trips through Repo.insert!/Repo.all" do
    # Confirms live that ClickHouse's plain `DateTime` is timezone-naive
    # storage (a bare Unix-epoch second count, not tagged with any zone) --
    # `NativeBlock.decode_datetime/1` always decodes it as UTC, which is the
    # correct interpretation as long as values are also written as UTC (as
    # they are here: `Connection.encode_literal/1` renders a `%DateTime{}`
    # via `DateTime.to_string/1`, and `TestRepo.insert!/1` dumps a
    # `:utc_datetime` field's `%DateTime{}` un-shifted).
    utc = DateTime.from_naive!(~N[2024-03-15 12:34:56], "Etc/UTC")

    TestRepo.insert!(%UtcTimestampMeasurement{id: 1, recorded_at: utc})

    assert [%UtcTimestampMeasurement{id: 1, recorded_at: ^utc}] =
             UtcTimestampMeasurement |> TestRepo.all()
  end
end
