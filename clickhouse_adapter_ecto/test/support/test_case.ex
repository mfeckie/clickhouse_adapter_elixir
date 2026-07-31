defmodule Ecto.Adapters.ClickHouse.TestCase do
  @moduledoc """
  Reusable per-test isolation helper for this adapter's own integration
  suite, and a template downstream users of the adapter can copy for their
  own test suites -- see `## Recommended pattern for downstream users`
  below, and the "Testing" section of the top-level README, for the
  writeup this module exists to back up.

  ## Why not `Ecto.Adapters.SQL.Sandbox`

  `Ecto.Adapters.SQL.Sandbox` gives Postgres/MyXQL-based Ecto test suites
  fast, fully-isolated per-test state by wrapping each test in a real
  database transaction (`BEGIN`, optionally a nested `SAVEPOINT` per
  `checkout`) that's rolled back at the end instead of committed. That
  entire mechanism is unavailable here, confirmed two ways rather than
  assumed:

    * **Empirically**, against this repo's pinned
      `clickhouse/clickhouse-server:26.7` (see `clickhouse_adapter_ecto/docker-compose.yml`):
      calling `Repo.transaction(fn -> ... end)` doesn't silently no-op or
      succeed -- it raises `DBConnection.ConnectionError` with message
      `"transactions are not supported by ChDriver.DBConnection: :not_supported"`.
      That's because `ChDriver.DBConnection.handle_begin/2`,
      `handle_commit/2`, and `handle_rollback/2` (see
      `ch_driver/lib/ch_driver/db_connection.ex`) are deliberate
      unimplemented stubs that return `{:error, ...}` rather than pretend
      to support something the native protocol as used here doesn't. The
      connection pool remains perfectly usable immediately afterwards
      (verified in the same probe) -- this is a clean, documented "not
      supported" error, not a crash.
    * **From ClickHouse's own docs** (clickhouse.com/docs/guides/developer/
      transactional, current as of this investigation): ClickHouse does
      have an experimental multi-statement transaction feature
      (`allow_experimental_transactions`), but it (a) requires ClickHouse
      Keeper or ZooKeeper to be deployed as a coordination layer -- this
      repo's `docker-compose.yml` runs no such service, only ClickHouse and
      a Kafka broker -- (b) only covers non-replicated `MergeTree` tables
      under the `Atomic` database engine (not e.g. the `Memory` engine table
      `repo_test.exs` uses), (c) is explicitly documented as experimental
      with "changes should be expected" and unsupported on ClickHouse
      Cloud, and (d) aborts the *entire* transaction on any exception,
      including a typo'd function name -- far too fragile a foundation for
      a test helper meant to make tests *more* robust. Ruled out on
      substance, not just because `ChDriver` doesn't wire it up: even if
      `ChDriver` grew support for it, adopting it here would mean bringing
      up a Keeper service in `docker-compose.yml` and accepting the
      per-exception-aborts-everything behavior, for an "experimental"
      feature ClickHouse itself doesn't consider stable.

  With no real transaction to roll back, there is nothing for a
  Sandbox-*compatible* checkout/ownership wrapper to sit on top of --
  attempting one would mean building an entirely different (and
  misleadingly-named) mechanism under the `Sandbox` API, which would be
  worse than just documenting a different pattern plainly. So this module
  does the latter.

  ## The chosen approach: shared tables, TRUNCATE-before-each-test reset

  This mirrors what every integration test file in `test/integration/`
  already did by hand before this module existed (see e.g. the pre-existing
  `setup_all`/`setup`/`on_exit` blocks in `repo_test.exs`,
  `nullable_test.exs`, etc.): create the table(s) for a whole test module
  once in `setup_all` (ClickHouse DDL is non-transactional and relatively
  slow -- a `CREATE TABLE`/`DROP TABLE` per *test*, rather than per module,
  would be needless overhead), `TRUNCATE` them in a plain `setup` before
  every test (fast -- a metadata operation on `MergeTree`/`Memory` tables,
  not a scan-and-delete), and `DROP TABLE` once in `on_exit` when the whole
  module is done. This module just factors that pattern into one call
  instead of ~30 lines of copy-pasted `ChDriver.start_link`/`query`/
  `on_exit` boilerplate per test file.

  Tradeoffs, weighed explicitly against the other two alternatives from
  this investigation:

    * **vs. TRUNCATE-based reset done ad hoc per file (the status quo before
      this module)**: same runtime behavior, far less boilerplate, and one
      place to fix bugs in the pattern instead of nine. This is what this
      module *is*.
    * **vs. a per-test(-module) uniquely-named database** (`CREATE DATABASE
      test_<n>`, run migrations, `DROP DATABASE` after -- fully supported
      today via `Ecto.Adapters.ClickHouse.storage_up/1`/`storage_down/1`):
      that approach buys `async: true` (genuinely concurrent test modules
      each in their own database, no shared-table interference), at the
      cost of a `CREATE DATABASE`/migration-run/`DROP DATABASE` per test
      *module* rather than a cheap `TRUNCATE` per *test*. It's the better
      choice if a downstream suite is large enough that `async: true`
      meaningfully speeds up CI, or if tests legitimately need concurrent,
      independent schemas. This repo's own suite is small and already
      `async: false` throughout (every integration test file shares the
      one ClickHouse instance and, in several cases, deliberately exercises
      the *same* pool concurrently via `Task.async_stream/3` -- see
      `repo_advanced_test.exs` -- which is itself incompatible with
      per-test database isolation), so the TRUNCATE approach is strictly
      simpler here with no real downside. Downstream users who want
      `async: true` should reach for the unique-database pattern instead --
      documented in the README's "Testing" section with a worked example.

  ## Usage

      defmodule MyApp.SomeIntegrationTest do
        use ExUnit.Case, async: false
        import Ecto.Adapters.ClickHouse.TestCase

        defmodule TestRepo do
          use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
        end

        setup_clickhouse_tables TestRepo,
          widgets: "CREATE TABLE widgets (id UInt64, name String) ENGINE = MergeTree ORDER BY id"

        test "..." do
          TestRepo.insert!(%Widget{id: 1, name: "gizmo"})
          assert [%Widget{id: 1}] = TestRepo.all(Widget)
        end
      end

  The keyword list's keys double as the table names passed to `DROP TABLE`/
  `TRUNCATE TABLE`, so they must match the table name each DDL string
  actually creates. `setup_clickhouse_tables/3` expands to a `setup_all`
  that starts `TestRepo`, drops-then-creates every listed table (in the
  order given -- list tables with foreign-key-like references, e.g.
  `join_comments` referencing `join_posts`, after the tables they reference,
  matching this module's `DROP` ordering, which walks the list in reverse),
  registers an `on_exit` to drop them again, and a plain `setup` that
  `TRUNCATE`s every listed table before each test.
  """

  alias Ecto.Adapters.ClickHouse.TestSupport.Ddl

  @doc """
  Expands to a `setup_all` (start `repo`, create every table in
  `table_ddls`, register `on_exit` to drop them) and a `setup` (`TRUNCATE`
  every table) -- see the moduledoc above for the full rationale and an
  example.

  `table_ddls` is a keyword list of `table_name: "CREATE TABLE ...”`
  (evaluated at compile time in the caller, so plain literals -- not
  runtime-computed values -- are expected, same as any other ExUnit
  `setup`/`setup_all` block). `connect_opts` overrides/extends the default
  connection options (`hostname: "localhost", port: 9000, username:
  "default", password: ""`, `database: "default"`) used both for the
  `Ecto.Repo` started here and the raw `ChDriver` connection used for
  DDL/TRUNCATE.
  """
  defmacro setup_clickhouse_tables(repo, table_ddls, connect_opts \\ []) do
    quote bind_quoted: [repo: repo, table_ddls: table_ddls, connect_opts: connect_opts] do
      setup_all do
        Ecto.Adapters.ClickHouse.TestCase.__start_repo__(unquote(repo), unquote(connect_opts))
        Ecto.Adapters.ClickHouse.TestCase.__create_tables__(unquote(table_ddls), unquote(connect_opts))

        on_exit(fn ->
          Ecto.Adapters.ClickHouse.TestCase.__drop_tables__(unquote(table_ddls), unquote(connect_opts))
        end)

        :ok
      end

      setup do
        Ecto.Adapters.ClickHouse.TestCase.__truncate_tables__(unquote(table_ddls), unquote(connect_opts))
        :ok
      end
    end
  end

  @doc false
  def __start_repo__(repo, connect_opts) do
    opts =
      Ddl.default_connect_opts()
      |> Keyword.put(:database, "default")
      |> Keyword.put(:pool_size, 5)
      |> Keyword.merge(connect_opts)

    {:ok, _pid} = repo.start_link(opts)
    :ok
  end

  @doc false
  def __create_tables__(table_ddls, connect_opts) do
    Ddl.create_tables(table_ddls, connect_opts, "setup_clickhouse_tables failed to create table")
  end

  @doc false
  def __drop_tables__(table_ddls, connect_opts) do
    Ddl.drop_tables(table_ddls, connect_opts)
  end

  @doc false
  def __truncate_tables__(table_ddls, connect_opts) do
    Ddl.with_ddl_conn(connect_opts, fn conn ->
      for {table, _ddl} <- table_ddls do
        case ChDriver.query(conn, "TRUNCATE TABLE #{table}") do
          {:ok, _} ->
            :ok

          {:error, error} ->
            raise "setup_clickhouse_tables failed to truncate table #{table}: #{Exception.message(error)}"
        end
      end
    end)

    :ok
  end
end
