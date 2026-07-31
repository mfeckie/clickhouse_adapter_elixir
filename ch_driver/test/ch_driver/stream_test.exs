defmodule ChDriver.StreamTest do
  @moduledoc """
  Integration tests for real, incremental streaming (`clickhouse_adapter_elixir-szk.7`):
  `ChDriver.DBConnection.handle_declare/4`, `handle_fetch/4`,
  `handle_deallocate/4` (backed by `ChDriver.Connection.start_stream/3`,
  `stream_fetch/2`, `cancel_stream/2`), and `ChDriver.Stream`'s `Enumerable`
  impl.

  Each element a `ChDriver.Stream` yields is one ClickHouse wire-protocol
  Data block (a `%ChDriver.Result{}`), not one row -- matching
  `Postgrex.Stream`'s own chunk-per-fetch semantics (see
  `postgrex/lib/postgrex.ex`'s `@max_rows`/`stream/4` moduledoc: "Stream
  consumes memory in chunks of at most max_rows rows"). ClickHouse's own
  block size is controlled with the `max_block_size` query setting, which
  the tests below use to get deterministic, small multi-block results
  without needing millions of rows.

  ## A discovered nuance: early-halt cleanup cost is real

  `handle_deallocate/4`'s Cancel-and-drain cleanup (see
  `ChDriver.Connection.cancel_stream/2`) runs *synchronously* as part of
  the very `Enum.take/2` (or any other early-halting) call that triggers
  it -- `Stream.resource/3`'s `stop` callback isn't deferred to some later
  point, it's invoked before control returns to the caller. For a fast,
  simple query (e.g. `system.numbers`), ClickHouse has often already
  pushed the *entire* result into the socket by the time our Cancel
  packet would reach it, so "draining to `:end_of_stream`" ends up
  meaning "decode everything anyway" -- it still saves memory (rows are
  discarded per block instead of accumulated into one giant list) but
  does *not* make an early `Enum.take/2` return in less wall-clock time
  than consuming the whole thing would have. The "genuinely incremental"
  test below deliberately measures first-block arrival against a
  *natural* full consumption (no early halt) to avoid conflating the two
  costs; the halting tests use small (≤1000-row) results specifically so
  this drain cost stays negligible there.
  """

  use ExUnit.Case, async: true

  alias ChDriver.Result

  @moduletag :integration

  describe "genuinely incremental: the first block arrives without waiting for the full result" do
    setup do
      {:ok, pool} = ChDriver.start_link(pool_size: 1)
      %{pool: pool}
    end

    test "the first block arrives in a small fraction of the time consuming the whole stream takes",
         %{pool: pool} do
      # Large enough (and with a `toString` conversion, not just a bare
      # integer column, to add real per-row work) that fully receiving/
      # decoding it takes measurable wall-clock time even against a
      # local, unloaded ClickHouse -- while still spanning several blocks
      # at the default block size (65536 rows), so there is plenty left
      # to receive after the first one.
      #
      # This deliberately consumes the stream to its *natural* end
      # (`Enum.reduce/3`, no early `Enum.take/2`) rather than halting
      # partway -- halting early would also exercise
      # `handle_deallocate/4`'s Cancel-and-drain cleanup (see its
      # moduledoc), whose own cost (discovered while writing this test:
      # ClickHouse had already pushed the *entire* result for a query
      # this fast/simple into the socket before ever seeing our Cancel,
      # so draining it is essentially "decode everything anyway") would
      # swamp the measurement and make it meaningless. Measuring
      # first-block-arrival against a full *natural* run isolates the
      # one thing this test is actually about: whether the first chunk
      # is handed to the consumer as soon as it's decoded, or only after
      # everything has been buffered internally first.
      statement = "SELECT number, toString(number) AS s FROM system.numbers LIMIT 300000"
      opts = [recv_timeout: 30_000, timeout: 30_000]
      test_pid = self()
      start_time = System.monotonic_time(:microsecond)

      {total_time_us, {block_count, row_count}} =
        :timer.tc(fn ->
          DBConnection.run(
            pool,
            fn conn ->
              conn
              |> ChDriver.stream(statement, [], opts)
              |> Enum.reduce({0, 0}, fn %Result{rows: rows}, {blocks, rows_seen} ->
                if blocks == 0 do
                  send(test_pid, {:first_block_at, System.monotonic_time(:microsecond)})
                end

                {blocks + 1, rows_seen + length(rows)}
              end)
            end,
            opts
          )
        end)

      assert row_count == 300_000
      # Several blocks, not one -- confirms this genuinely spans more
      # than a single Data block (default block size is 65536 rows).
      assert block_count > 1

      assert_received {:first_block_at, first_block_at}
      first_block_time_us = first_block_at - start_time

      # The load-bearing assertion: if `handle_declare/4` (or
      # `ChDriver.Connection.start_stream/3` underneath it) silently ran
      # the *entire* query to `:end_of_stream` and only *presented*
      # blocks one at a time afterwards (buffering everything internally
      # first, then merely trickling it back out through the
      # Enumerable), the first block would only become available at
      # essentially the same instant as the last one -- `first_block_time_us`
      # would be indistinguishable from `total_time_us`. Genuinely
      # incremental delivery means the first block is hashed out and
      # handed back long before the rest of the 300,000 rows have even
      # been decoded.
      assert first_block_time_us < total_time_us / 3,
             "expected the first streamed block (#{first_block_time_us}us) to arrive in a small " <>
               "fraction of the whole stream's consumption time (#{total_time_us}us) -- got a " <>
               "ratio of #{Float.round(first_block_time_us / total_time_us, 3)}, suggesting the " <>
               "stream buffers the whole result before yielding anything"
    end
  end

  describe "halting partway through a stream" do
    setup do
      {:ok, pool} = ChDriver.start_link(pool_size: 1)
      %{pool: pool}
    end

    test "Enum.take(stream, 5) on a 1000-row result halts early, deallocates, and leaves the connection usable",
         %{pool: pool} do
      # `max_block_size = 50` forces the 1000-row result across 20 blocks
      # instead of ClickHouse's default single ~65536-row block, so
      # `Enum.take(stream, 5)` (5 blocks = 250 rows) genuinely stops well
      # before the result ends, exercising `handle_deallocate/4`'s
      # early-cancel/drain path (`ChDriver.Connection.cancel_stream/2`)
      # instead of its `done: true` no-op fast path.
      statement =
        "SELECT number FROM system.numbers LIMIT 1000 SETTINGS max_block_size = 50"

      blocks =
        DBConnection.run(pool, fn conn ->
          conn |> ChDriver.stream(statement) |> Enum.take(5)
        end)

      assert length(blocks) == 5

      total_rows = Enum.reduce(blocks, 0, fn %Result{rows: rows}, acc -> acc + length(rows) end)
      assert total_rows == 250

      for %Result{rows: rows} <- blocks do
        assert length(rows) == 50
      end

      # The connection must still be perfectly usable afterwards -- proves
      # `handle_deallocate/4` actually cleaned up (sent Cancel and drained
      # to `:end_of_stream`) rather than leaving unread bytes from the
      # abandoned query sitting on the socket, which would desync every
      # byte read by the next request.
      assert {:ok, %Result{rows: [[1]]}} = ChDriver.query(pool, "SELECT 1")
      assert {:ok, %Result{rows: [[42]]}} = ChDriver.query(pool, "SELECT 42")
    end

    test "consuming a stream to completion naturally (no early halt) still deallocates cleanly and the connection stays usable",
         %{pool: pool} do
      statement = "SELECT number FROM system.numbers LIMIT 500 SETTINGS max_block_size = 50"

      blocks =
        DBConnection.run(pool, fn conn ->
          conn |> ChDriver.stream(statement) |> Enum.to_list()
        end)

      total_rows = Enum.reduce(blocks, 0, fn %Result{rows: rows}, acc -> acc + length(rows) end)
      assert total_rows == 500

      assert {:ok, %Result{rows: [[7]]}} = ChDriver.query(pool, "SELECT 7")
    end

    test "repeated stream/take/discard cycles never leave the connection desynced", %{
      pool: pool
    } do
      statement = "SELECT number FROM system.numbers LIMIT 1000 SETTINGS max_block_size = 50"

      for n <- 1..5 do
        blocks =
          DBConnection.run(pool, fn conn ->
            conn |> ChDriver.stream(statement) |> Enum.take(n)
          end)

        assert length(blocks) == n
      end

      assert {:ok, %Result{rows: [[99]]}} = ChDriver.query(pool, "SELECT 99")
    end
  end

  describe "stream contents/decoding" do
    setup do
      {:ok, pool} = ChDriver.start_link(pool_size: 1)
      %{pool: pool}
    end

    test "rows across all blocks match a non-streamed query for the same statement", %{
      pool: pool
    } do
      statement = "SELECT number FROM system.numbers LIMIT 300 SETTINGS max_block_size = 100"

      assert {:ok, %Result{rows: expected_rows}} = ChDriver.query(pool, statement)

      streamed_rows =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream(statement)
          |> Enum.flat_map(fn %Result{rows: rows} -> rows end)
        end)

      assert streamed_rows == expected_rows
      assert length(streamed_rows) == 300
    end

    test "opts[:decode_mapper] is honored per block, exactly like query/4", %{pool: pool} do
      statement = "SELECT number FROM system.numbers LIMIT 150 SETTINGS max_block_size = 50"

      mapped_rows =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream(statement, [], decode_mapper: fn [n] -> n * 2 end)
          |> Enum.flat_map(fn %Result{rows: rows} -> rows end)
        end)

      assert mapped_rows == Enum.map(0..149, &(&1 * 2))
    end

    test "params bind through the stream the same way they do for query/4", %{pool: pool} do
      rows =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream("SELECT ? AS n", [7])
          |> Enum.flat_map(fn %Result{rows: rows} -> rows end)
        end)

      assert rows == [[7]]
    end

    test "an empty result set still declares/fetches/deallocates cleanly", %{pool: pool} do
      rows =
        DBConnection.run(pool, fn conn ->
          conn
          |> ChDriver.stream("SELECT number FROM system.numbers LIMIT 0")
          |> Enum.flat_map(fn %Result{rows: rows} -> rows end)
        end)

      assert rows == []

      assert {:ok, %Result{rows: [[1]]}} = ChDriver.query(pool, "SELECT 1")
    end
  end
end
