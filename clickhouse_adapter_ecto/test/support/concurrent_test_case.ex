defmodule Ecto.Adapters.ClickHouse.ConcurrentTestCase do
  @moduledoc """
  Additive, `async: true`-compatible alternative to
  `Ecto.Adapters.ClickHouse.TestCase`'s TRUNCATE-based
  `setup_clickhouse_tables/3`. This module does **not** replace that one --
  see `Ecto.Adapters.ClickHouse.TestCase`'s moduledoc first if you haven't;
  it remains the right default for most suites. This module exists for the
  narrower case where a suite is large enough (or exercises `MergeTree`
  engines heavily enough) that `async: true` is worth the extra moving parts
  below.

  This module investigates a different mechanism from the TRUNCATE-based
  helper above (which already ruled out `Ecto.Adapters.SQL.Sandbox`'s
  transaction-rollback mechanism -- ClickHouse has no usable transactions,
  see that module's moduledoc): per-connection `CREATE TEMPORARY TABLE`
  shadowing, with one physical connection pinned to one test process for
  the test's duration via `DBConnection.Ownership`.

  ## Empirical findings this is built on (verified live against this repo's
  pinned `clickhouse/clickhouse-server:24.8`, `docker-compose.yml`)

  1. **Temp-table shadowing is real.** On a connection that has run
     `CREATE TEMPORARY TABLE widgets (...)`, an unqualified `SELECT * FROM
     widgets` (exactly what Ecto generates -- no database prefix) returns the
     *temporary* table's rows, not the permanent table's, even though both
     exist simultaneously under the same name. A second, separate connection
     querying `widgets` sees only the permanent table's data, completely
     unaffected. Confirmed with a permanent-table row and a
     differently-valued temporary-table row present at the same time, on
     three separate connections (one with the shadow, two without).
  2. **Not Memory-only.** `CREATE TEMPORARY TABLE ... ENGINE = MergeTree
     ORDER BY id` (and `ReplacingMergeTree`, `Log`, `TinyLog`) all succeeded
     in direct testing against 24.8 -- ClickHouse's docs are ambiguous/dated
     on this point, so this was tested directly rather than trusted. This
     means a temp-table shadow can use the **same engine as the real table**
     (this module does exactly that -- see `## How shadowing works` below),
     so `MergeTree`-specific behavior your tests exercise (`ORDER BY`-driven
     sort, `ReplacingMergeTree` dedup, etc.) is *not* automatically lost the
     way the original design hypothesis worried it might be. (Nothing here
     changes the fact that ClickHouse `MergeTree` merges/dedup are
     asynchronous and eventually-consistent regardless of engine choice --
     that's a pre-existing ClickHouse property, not something this mechanism
     introduces or fixes.)
  3. **Cleanup on disconnect is real, no `DISCARD` needed.** Closing the TCP
     connection that created a temp table and reconnecting confirms the temp
     table is simply gone (`Unknown table expression identifier`) -- no
     leak, and the permanent table is untouched throughout.
  4. **`DBConnection.Ownership` pins a connection to a process, with zero
     transaction involvement.** There is no public `DBConnection.checkout/2`
     -- the actual public primitives are `DBConnection.run/3` (scoped to one
     callback, not useful for spanning a whole `test do ... end` block) and
     `DBConnection.Ownership`, a *pool module* (`@behaviour DBConnection.Pool`)
     that proxies checkouts to a per-owner-process connection via
     `ownership_checkout/2`/`ownership_checkin/2`/`ownership_allow/3`. Its own
     moduledoc describes it purely as "a mechanism to coordinate between
     processes" -- transaction-wrapping (`:post_checkout`/`:pre_checkin`) is
     an *optional, separate* layer `Ecto.Adapters.SQL.Sandbox` adds on top,
     which this module never touches, since there's no `handle_begin`/
     `handle_commit`/`handle_rollback` to hang it on anyway (see
     `Ecto.Adapters.ClickHouse.TestCase`'s moduledoc). Verified directly
     against this adapter's own pool (started with `pool:
     DBConnection.Ownership, ownership_mode: :manual`): checkout pins one
     physical connection to the calling process (confirmed via a
     session-scoped temp table staying visible across two *separate* query
     calls from that process), an unrelated process is correctly rejected
     with a clear `OwnershipError` unless explicitly allowed or it inherits
     `$callers` (the same mechanism `Task.async/1` already sets up, and the
     same one `Ecto.Adapters.SQL.Sandbox` relies on), checkin releases it
     cleanly, and the pool remains fully reusable afterwards.

  All four checked out, which is why this module exists.

  ## How shadowing works

  `table_ddls` (same shape as `Ecto.Adapters.ClickHouse.TestCase`'s) gives a
  literal `"CREATE TABLE <name> (...) ENGINE = ..."` string per table. This
  module creates that table for real, once, in `setup_all` (a permanent
  table other connections/tests-in-other-modules can never see mutated,
  since every mutating test only ever touches its own shadow). In each
  test's `setup`, it:

    1. Checks out one physical connection from the repo's pool, pinned to
       the test process for the test's duration (`ownership_checkout`).
    2. On that connection: `DROP TABLE IF EXISTS <name>` (idempotently drops
       a leftover shadow from whichever *earlier* test last held this same
       physical connection -- confirmed empirically that an unqualified
       `DROP TABLE IF EXISTS` on a shadowed connection drops only the
       *temporary* table, never the permanent one underneath, so this is
       safe even though both exist under the same name on this connection),
       then re-issues the same DDL with `CREATE TABLE` swapped for `CREATE
       TEMPORARY TABLE` (same columns, same `ENGINE`/`ORDER BY` clause as
       the real table).
    3. Registers `on_exit` to `ownership_checkin` the connection back to the
       pool for reuse by whichever test acquires it next.

  Every unqualified query Ecto generates for that repo, from that test
  process, transparently hits the shadow -- no query/schema changes needed
  on the test's part.

  ## Tradeoffs (read before reaching for this over `TestCase`)

    * **`pool_size` must be >= the number of test *processes* that will
      concurrently hold a checkout** -- exactly the same constraint
      `Ecto.Adapters.SQL.Sandbox` has for Postgres/MyXQL suites. Undersizing
      it doesn't corrupt anything; a test just blocks waiting for a free
      connection (or times out) until one frees up. `__start_repo__/2`
      defaults to `pool_size: 10`; override via `connect_opts` if your suite
      runs a lot of `async: true` modules concurrently (ExUnit itself caps
      concurrency at online scheduler count, so this rarely needs to be
      large).
    * **The `Ownership` pool is `:manual` mode, and manual mode is strict**:
      any process that queries the repo without first being checked out (or
      `$callers`-linked to one that is) gets a clear `OwnershipError`, not a
      silent fallback to a shared/permanent connection. If a test spawns a
      bare `spawn/1` process (not `Task.async/1`, which sets `$callers`
      automatically) and expects it to query the repo, that process must be
      explicitly `ownership_allow`ed -- there is no macro-level helper for
      that here (yet) since none of this repo's own tests need it.
    * **DDL changes on the shadowed connection only affect that connection's
      shadow**, by construction -- if a test needs to `ALTER`/`CREATE
      INDEX`/etc. against the *real* table as part of what it's testing, this
      mechanism is the wrong tool; reach for `TestCase` (shared real table)
      or a per-module unique database instead.
    * **Still no real transactions.** A test failing partway through a
      multi-statement sequence leaves whatever partial state it wrote in its
      shadow -- harmless, since the *next* test's `setup` unconditionally
      drops and recreates that shadow before it runs, same failure-isolation
      story `TestCase`'s TRUNCATE already has.

  ## Usage

      defmodule MyApp.SomeIntegrationTest do
        use ExUnit.Case, async: true
        import Ecto.Adapters.ClickHouse.ConcurrentTestCase

        defmodule TestRepo do
          use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
        end

        setup_clickhouse_shadow_tables TestRepo,
          widgets: "CREATE TABLE widgets (id UInt64, name String) ENGINE = MergeTree ORDER BY id"

        test "..." do
          TestRepo.insert!(%Widget{id: 1, name: "gizmo"})
          assert [%Widget{id: 1}] = TestRepo.all(Widget)
        end
      end

  Same DDL-string/table-name-matching rule as `TestCase`: each `table_ddls`
  entry's key must match the table name its DDL string's `CREATE TABLE`
  clause actually creates (this module rewrites exactly that clause to
  `CREATE TEMPORARY TABLE`, so a mismatch raises a clear error at test-setup
  time rather than silently shadowing the wrong table).
  """

  alias Ecto.Adapters.ClickHouse.TestSupport.Ddl

  @default_pool_size 10

  @doc """
  Expands to a `setup_all` (start `repo` with an `Ownership`-pooled
  connection pool, create every real table in `table_ddls`, register
  `on_exit` to drop them) and a `setup` (check out one physical connection
  pinned to the test process, drop-then-recreate every table in
  `table_ddls` as a `CREATE TEMPORARY TABLE` shadow on that connection,
  register `on_exit` to check the connection back in) -- see the moduledoc
  above for the full rationale, the empirical findings backing it, and the
  tradeoffs to weigh against `Ecto.Adapters.ClickHouse.TestCase`.

  `table_ddls` and `connect_opts` have the same shape as
  `Ecto.Adapters.ClickHouse.TestCase.setup_clickhouse_tables/3`.
  `connect_opts` additionally accepts `:pool_size` to size the repo's
  connection pool (default #{@default_pool_size} -- must be at least the
  number of test processes that will concurrently hold a checkout).
  """
  defmacro setup_clickhouse_shadow_tables(repo, table_ddls, connect_opts \\ []) do
    quote bind_quoted: [repo: repo, table_ddls: table_ddls, connect_opts: connect_opts] do
      setup_all do
        Ecto.Adapters.ClickHouse.ConcurrentTestCase.__start_repo__(
          unquote(repo),
          unquote(connect_opts)
        )

        Ecto.Adapters.ClickHouse.ConcurrentTestCase.__create_permanent_tables__(
          unquote(table_ddls),
          unquote(connect_opts)
        )

        on_exit(fn ->
          Ecto.Adapters.ClickHouse.ConcurrentTestCase.__drop_tables__(
            unquote(table_ddls),
            unquote(connect_opts)
          )
        end)

        :ok
      end

      setup do
        Ecto.Adapters.ClickHouse.ConcurrentTestCase.__checkout__(unquote(repo))

        on_exit(fn ->
          Ecto.Adapters.ClickHouse.ConcurrentTestCase.__checkin__(unquote(repo))
        end)

        Ecto.Adapters.ClickHouse.ConcurrentTestCase.__shadow_tables__(
          unquote(repo),
          unquote(table_ddls)
        )

        :ok
      end
    end
  end

  @doc false
  def __start_repo__(repo, connect_opts) do
    opts =
      Ddl.default_connect_opts()
      |> Keyword.put(:database, "default")
      |> Keyword.put(:pool, DBConnection.Ownership)
      |> Keyword.put(:ownership_mode, :manual)
      |> Keyword.put(:pool_size, @default_pool_size)
      |> Keyword.merge(connect_opts)

    case repo.start_link(opts) do
      {:ok, _pid} -> :ok
      # `setup_all` may run this more than once if a previous test run left
      # the repo registered (e.g. under `iex -S mix test`) -- treat an
      # already-started repo the same as a fresh one rather than crashing.
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def __create_permanent_tables__(table_ddls, connect_opts) do
    Ddl.create_tables(
      table_ddls,
      connect_opts,
      "setup_clickhouse_shadow_tables failed to create table"
    )
  end

  @doc false
  def __drop_tables__(table_ddls, connect_opts) do
    Ddl.drop_tables(table_ddls, connect_opts)
  end

  @doc false
  def __checkout__(repo) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo)

    case DBConnection.Ownership.ownership_checkout(pool, []) do
      :ok -> :ok
      {:already, _} -> :ok
    end
  end

  @doc false
  def __checkin__(repo) do
    %{pid: pool} = Ecto.Adapter.lookup_meta(repo)
    DBConnection.Ownership.ownership_checkin(pool, [])
    :ok
  end

  @doc false
  def __shadow_tables__(repo, table_ddls) do
    for {table, ddl} <- table_ddls do
      temp_ddl = to_temporary_ddl!(table, ddl)

      # Same connection the test process just checked out (Ownership routes
      # this call there via the process's own ownership entry) -- dropping
      # here only ever removes a *previous* test's leftover shadow, never
      # the permanent table (confirmed empirically: an unqualified DROP on a
      # shadowed connection targets the temporary table).
      Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS #{table}", [])
      Ecto.Adapters.SQL.query!(repo, temp_ddl, [])
    end

    :ok
  end

  defp to_temporary_ddl!(table, ddl) do
    prefix = "CREATE TABLE #{table} "

    if String.starts_with?(ddl, prefix) do
      String.replace_prefix(ddl, "CREATE TABLE ", "CREATE TEMPORARY TABLE ")
    else
      raise "setup_clickhouse_shadow_tables: table #{inspect(table)}'s DDL string must start " <>
              "with #{inspect(prefix)} so it can be rewritten to CREATE TEMPORARY TABLE -- got: #{inspect(ddl)}"
    end
  end

end
