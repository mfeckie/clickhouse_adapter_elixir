defmodule ChDriver.ConnectionTest do
  use ExUnit.Case, async: true

  alias ChDriver.Connection
  alias ChDriver.Protocol.ServerHello

  @moduletag :integration

  describe "connect/1 against a live ClickHouse server" do
    test "performs the Hello handshake and returns real server info" do
      assert {:ok, %{socket: socket, server_info: server_info}} = Connection.connect()

      on_exit(fn -> :ok end)
      Connection.close(socket)

      assert %ServerHello{} = server_info
      assert server_info.name == "ClickHouse"
      assert is_integer(server_info.version_major) and server_info.version_major >= 0
      assert is_integer(server_info.version_minor) and server_info.version_minor >= 0
      assert is_integer(server_info.revision) and server_info.revision > 0
      assert is_binary(server_info.timezone) and server_info.timezone != ""
      assert is_binary(server_info.display_name)
      assert is_integer(server_info.version_patch)
    end

    test "returns an error for an unreachable host (connection refused)" do
      assert {:error, _reason} =
               Connection.connect(hostname: "localhost", port: 1, connect_timeout: 500)
    end

    test "fails cleanly rather than hanging against a blackholed host (connect timeout)" do
      # 203.0.113.0/24 is TEST-NET-3 (RFC 5737) -- reserved for documentation,
      # never routable -- so this exercises the *timeout* path of
      # `:gen_tcp.connect/4` (packets silently dropped) rather than the
      # immediate ECONNREFUSED exercised by the "unreachable host" test
      # above. connect/1 must return promptly once `:connect_timeout`
      # elapses, not hang indefinitely.
      {time_us, result} =
        :timer.tc(fn ->
          Connection.connect(hostname: "203.0.113.1", port: 9000, connect_timeout: 300)
        end)

      assert {:error, _reason} = result
      # Generous upper bound (well above the 300ms connect_timeout) purely
      # to catch a genuine hang, not to assert tight timing.
      assert time_us < 5_000_000
    end

    test "ping/1 succeeds repeatedly on the same connection" do
      assert {:ok, conn} = Connection.connect()
      on_exit(fn -> Connection.close(conn.socket) end)

      for _ <- 1..5 do
        assert :ok = Connection.ping(conn)
      end
    end
  end
end
