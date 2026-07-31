defmodule Ecto.Adapters.ClickHouse.TestSupport.Ddl do
  @moduledoc false

  @default_connect_opts [hostname: "localhost", port: 9000, username: "default", password: ""]

  @doc false
  def default_connect_opts, do: @default_connect_opts

  @doc false
  def with_ddl_conn(connect_opts, fun) do
    opts =
      @default_connect_opts
      |> Keyword.put(:database, "default")
      |> Keyword.merge(connect_opts)
      |> Keyword.take([:hostname, :port, :database, :username, :password])

    {:ok, conn} = ChDriver.start_link(opts)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  @doc false
  def drop_tables(table_ddls, connect_opts) do
    with_ddl_conn(connect_opts, fn conn ->
      for {table, _ddl} <- Enum.reverse(table_ddls) do
        ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
      end
    end)

    :ok
  end

  @doc false
  def create_tables(table_ddls, connect_opts, error_prefix \\ "failed to create table") do
    with_ddl_conn(connect_opts, fn conn ->
      # Reverse order for DROP: a table listed after another (e.g.
      # `join_comments` after `join_posts`) is assumed to reference it, so
      # it must be dropped first to avoid depending on ClickHouse enforcing
      # (or not enforcing) any ordering itself.
      for {table, _ddl} <- Enum.reverse(table_ddls) do
        ChDriver.query(conn, "DROP TABLE IF EXISTS #{table}")
      end

      for {table, ddl} <- table_ddls do
        case ChDriver.query(conn, ddl) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            raise "#{error_prefix} #{table}: #{Exception.message(error)}"
        end
      end
    end)

    :ok
  end
end
