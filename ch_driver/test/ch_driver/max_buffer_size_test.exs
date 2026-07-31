defmodule ChDriver.MaxBufferSizeTest do
  @moduledoc """
  Exercises the `:max_buffer_size` guard in `ChDriver.Connection`'s receive
  loops (see `check_buffer_size/2` in `lib/ch_driver/connection.ex`) against
  a fake TCP server -- no live ClickHouse server required, unlike the rest
  of this test suite (contrast with `ChDriver.ConnectionTest`/
  `ChDriver.QueryTest`, both tagged `:integration`).

  The fake server performs a real (valid) Hello handshake so `connect/1`
  succeeds, then responds to the subsequent Query with a Data packet whose
  column-type string carries a garbled/oversized length prefix (tens of
  millions of declared bytes) backed by only a handful of actual bytes.
  Without a buffer-size cap, `receive_query_result/5` would keep calling
  `:gen_tcp.recv/3` and concatenating the result onto its buffer forever,
  waiting for bytes that will never arrive, only ever bounded by
  `recv_timeout`. With the cap (set very low here so the already-buffered
  garbled response trips it immediately, without any network waiting),
  the connection must fail fast with a clear `%ChDriver.Error{}` instead.
  """

  use ExUnit.Case, async: true

  alias ChDriver.Connection
  alias ChDriver.Error
  alias ChDriver.Protocol.Varint

  # Declares a ~50MB column-type string but is backed by only a few dozen
  # real bytes -- `Varint.decode_string/1` can never satisfy this, so the
  # decoder reports `:incomplete` indefinitely.
  @garbled_declared_length 50_000_000

  test "a garbled/oversized length prefix fails fast instead of growing the buffer unbounded" do
    {port, server} = start_fake_server()
    on_exit(fn -> Process.exit(server, :kill) end)

    assert {:ok, conn} = Connection.connect(hostname: "localhost", port: port)
    on_exit(fn -> Connection.close(conn.socket) end)

    {time_us, result} =
      :timer.tc(fn ->
        Connection.query(conn, "SELECT 1", max_buffer_size: 10, recv_timeout: 2_000)
      end)

    assert {:error, %Error{} = error} = result
    assert error.name == "ChDriver::MaxBufferSizeExceeded"
    assert Exception.message(error) =~ "exceeding the 10-byte max_buffer_size"

    # The oversized response is already sitting in the socket's receive
    # buffer by the time `query/3` reads it, so the guard must trip on the
    # first check -- well under `recv_timeout` (2s) -- rather than only
    # after timing out waiting for bytes that will never arrive.
    assert time_us < 1_000_000
  end

  defp start_fake_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    server_hello = build_server_hello()
    garbled_response = build_garbled_data_response()

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        # Read the ClientHello -- its bytes aren't parsed, this recv only
        # blocks us until the client has actually sent it.
        {:ok, _client_hello} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, server_hello)

        # Read whatever the client sends next (the post-ServerHello
        # Addendum, and/or the later Query+Data packet). This is a pure
        # synchronization point, not protocol parsing: `do_handshake/6`
        # only ever writes the Addendum *after* `receive_server_hello/4`
        # has already decoded our ServerHello above, so once anything
        # arrives here it's safe to send the garbled response -- sending
        # it any earlier risks it landing in the same read as ServerHello
        # itself, whose leftover `rest` bytes `receive_server_hello/4`
        # silently discards (a separate, pre-existing behavior), which
        # would swallow our garbled bytes before the client ever gets to
        # `receive_query_result/5`.
        {:ok, _addendum_or_more} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, garbled_response)
      end)

    {port, pid}
  end

  # A well-formed ServerHello (packet type 0) at a revision high enough
  # that `ChDriver.Protocol.decode_server_hello/1` expects (and this sends)
  # every optional field -- timezone, display name, version patch.
  defp build_server_hello do
    [
      Varint.encode(0),
      Varint.encode_string("Fake"),
      Varint.encode(1),
      Varint.encode(1),
      Varint.encode(54_465),
      Varint.encode_string("UTC"),
      Varint.encode_string("Fake"),
      Varint.encode(0)
    ]
    |> IO.iodata_to_binary()
  end

  # A Data packet (server packet type 1) with one column whose *type*
  # string's varint length prefix claims `@garbled_declared_length` bytes
  # but is backed by only a few dozen real bytes -- exactly the "garbled
  # length-prefix varint" scenario this guard exists for.
  defp build_garbled_data_response do
    [
      # packet type: Data
      Varint.encode(1),
      # table_name (empty)
      Varint.encode_string(""),
      # BlockInfo terminator (no is_overflows/bucket_num fields)
      Varint.encode(0),
      # num_columns, num_rows
      Varint.encode(1),
      Varint.encode(1),
      # column name
      Varint.encode_string("x"),
      # column type: garbled/oversized length prefix, way more bytes than
      # actually follow
      Varint.encode(@garbled_declared_length),
      String.duplicate("x", 30)
    ]
    |> IO.iodata_to_binary()
  end
end
