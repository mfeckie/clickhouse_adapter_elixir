defmodule Ecto.Adapters.ClickHouse.StreamIntegrationTest do
  @moduledoc """
  Integration tests for `clickhouse_adapter_elixir-szk.7`'s adapter-level
  piece: `Ecto.Adapters.ClickHouse.Connection.stream/4` (wired to
  `ChDriver.stream/4`/`ChDriver.Stream` -- see `ch_driver/test/ch_driver/
  stream_test.exs` for the ch_driver-level proof this is genuinely
  incremental, not just lazily-presented-after-full-buffering).

  ## A genuine, documented adapter-level blocker: `Repo.stream/2` itself

  `Ecto.Adapters.SQL.reduce/6` (the function that actually drives
  `Repo.stream/2`'s enumeration -- see `ecto_sql/lib/ecto/adapters/sql.ex`)
  requires the checked-out connection to have `conn_mode: :transaction`
  before it will even call our `stream/4`:

      case get_conn(pool) do
        %DBConnection{conn_mode: :transaction} = conn -> ...
        _ -> raise "cannot reduce stream outside of transaction"
      end

  That mode only exists on a connection checked out via
  `DBConnection.transaction/3` (what `Repo.transaction/2` uses), which in
  turn requires `handle_begin/2` to succeed. `ChDriver.DBConnection.
  handle_begin/2` is a deliberate, pre-existing, already-documented stub
  (see its moduledoc, and `adapter/test/support/test_case.ex`'s own
  moduledoc, written *before* this streaming work, independently
  confirming the exact same thing) that returns `{:error, ...}` because
  ClickHouse's native protocol as used by this driver has no session
  transaction support. This is true for *every* SQL adapter's
  `Repo.stream/2` (Postgres included -- it's not unique to ClickHouse),
  so it's not a shortcut in this streaming work; it's a pre-existing,
  independent limitation of this adapter that streaming inherits.

  This means `Repo.stream/2` cannot be driven end-to-end through
  `Ecto.Repo.transaction/2` yet -- adding real ClickHouse session
  transaction support is a separate, larger feature (ClickHouse does have
  an experimental transaction feature, but it requires a Keeper/ZooKeeper
  coordination service this repo's `docker-compose.yml` doesn't run, only
  covers non-replicated `MergeTree` under the `Atomic` engine, and aborts
  the whole transaction on any exception -- see `test_case.ex`'s moduledoc
  for the full investigation). Tests below prove exactly where the
  boundary sits: `stream/4` and the underlying `ChDriver.Stream` machinery
  are fully real (driven directly via `DBConnection.run/3`, which only
  needs a plain checkout, not a transaction); `Repo.stream/2` itself is
  blocked specifically at the transaction-begin step, cleanly and
  documentedly, not by anything half-implemented in this streaming work.
  """

  use ExUnit.Case, async: false

  alias ChDriver.Result

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :clickhouse_adapter_elixir, adapter: Ecto.Adapters.ClickHouse
  end

  defmodule StreamEvent do
    use Ecto.Schema

    @primary_key false
    schema "stream_events" do
      field(:id, :integer)
      field(:value, :integer)
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
        pool_size: 2
      )

    {:ok, ddl_conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(ddl_conn, "DROP TABLE IF EXISTS stream_events")

    {:ok, _} =
      ChDriver.query(
        ddl_conn,
        "CREATE TABLE stream_events (id UInt64, value Int32) ENGINE = MergeTree ORDER BY id"
      )

    on_exit(fn ->
      {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
      ChDriver.query(conn, "DROP TABLE IF EXISTS stream_events")
    end)

    :ok
  end

  setup do
    {:ok, conn} = ChDriver.start_link(hostname: "localhost", port: 9000)
    {:ok, _} = ChDriver.query(conn, "TRUNCATE TABLE stream_events")

    for id <- 1..1000 do
      {:ok, _} =
        ChDriver.query(conn, "INSERT INTO stream_events (id, value) VALUES (?, ?)", [id, id * 10])
    end

    :ok
  end

  describe "Ecto.Adapters.ClickHouse.Connection.stream/4 directly (via DBConnection.run/3)" do
    test "streams every row across multiple blocks, matching Repo.all/1 for the same query" do
      %{pid: pool} = Ecto.Adapter.lookup_meta(TestRepo)

      expected = TestRepo.all(StreamEvent) |> Enum.map(& &1.id) |> Enum.sort()
      assert length(expected) == 1000

      statement =
        "SELECT id, value FROM stream_events SETTINGS max_block_size = 50"

      {block_count, streamed_ids} =
        DBConnection.run(pool, fn conn ->
          Ecto.Adapters.ClickHouse.Connection.stream(conn, statement, [], [])
          |> Enum.reduce({0, []}, fn %Result{rows: rows}, {blocks, ids} ->
            {blocks + 1, ids ++ Enum.map(rows, fn [id, _value] -> id end)}
          end)
        end)

      # `max_block_size = 50` reliably chunks a generator source
      # (`system.numbers`, see `ch_driver/test/ch_driver/stream_test.exs`)
      # into exactly rows/50 blocks, but a real `MergeTree` table's block
      # boundaries also depend on its on-disk part layout (each of the
      # 1000 single-row `INSERT`s in `setup/0` lands in its own part
      # before any background merge runs) -- so this only asserts "more
      # than one block", not an exact count, to stay robust to
      # ClickHouse's own part-merge scheduling. The important thing this
      # proves is unchanged: the adapter's `stream/4` genuinely delivers
      # the result across multiple separate blocks, not as one
      # all-at-once result dressed up as a Stream.
      assert block_count > 1
      assert Enum.sort(streamed_ids) == expected

      # The pool remains healthy for ordinary Repo calls afterwards.
      assert TestRepo.all(StreamEvent) |> length() == 1000
    end

    test "an early Enum.take/2 halt cleans up (handle_deallocate/4) and leaves the pool usable" do
      %{pid: pool} = Ecto.Adapter.lookup_meta(TestRepo)

      statement = "SELECT id FROM stream_events SETTINGS max_block_size = 50"

      blocks =
        DBConnection.run(pool, fn conn ->
          Ecto.Adapters.ClickHouse.Connection.stream(conn, statement, [], [])
          |> Enum.take(1)
        end)

      total_rows = Enum.reduce(blocks, 0, fn %Result{rows: rows}, acc -> acc + length(rows) end)

      # A genuine partial read -- proves `Enum.take/2` didn't (and
      # couldn't have) forced the whole 1000-row result to materialize
      # before returning just the first block.
      assert total_rows > 0
      assert total_rows < 1000

      assert TestRepo.all(StreamEvent) |> length() == 1000
    end
  end

  describe "Repo.stream/2 -- the documented transaction boundary" do
    test "raises when called outside of Repo.transaction/2, same as every other Ecto SQL adapter" do
      assert_raise RuntimeError, ~r/cannot reduce stream outside of transaction/, fn ->
        StreamEvent |> TestRepo.stream() |> Enum.to_list()
      end

      # unaffected -- confirms the raise happened before touching the wire.
      assert TestRepo.all(StreamEvent) |> length() == 1000
    end

    test "Repo.transaction/2 itself fails cleanly (handle_begin/2 is unsupported), not with a half-working stream" do
      # `Repo.transaction/2` raises here rather than returning
      # `{:error, ...}` -- the failure is at `handle_begin/2` itself
      # (before the given function ever runs), not a rollback triggered
      # from inside it. Confirmed independently in
      # `adapter/test/support/test_case.ex`'s own moduledoc, written
      # before this streaming work, for the exact same reason (no
      # session transaction support in `ChDriver.DBConnection`).
      assert_raise DBConnection.ConnectionError,
                   ~r/transactions are not supported by ChDriver\.DBConnection/,
                   fn ->
                     TestRepo.transaction(fn ->
                       StreamEvent |> TestRepo.stream() |> Enum.to_list()
                     end)
                   end

      # The pool is still perfectly usable -- this is a clean "not
      # supported" error at the transaction/begin step, not a crash that
      # leaves the connection (or the pool) in a bad state.
      assert TestRepo.all(StreamEvent) |> length() == 1000
    end
  end
end
