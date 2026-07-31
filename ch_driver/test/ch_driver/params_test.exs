defmodule ChDriver.ParamsTest do
  use ExUnit.Case, async: true

  import ChDriver.TestCase

  alias ChDriver.Connection
  alias ChDriver.Params

  @moduletag :integration

  setup do
    setup_connection()
  end

  describe "Connection.query/3 with :params against a live ClickHouse server" do
    test "binds a UInt64 parameter", %{conn: conn} do
      assert {:ok, %{rows: rows}} =
               Connection.query(conn, "SELECT {id:UInt64}", params: [{"id", "5"}])

      assert rows == [[5]]
    end

    test "binds multiple parameters in one query", %{conn: conn} do
      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {a:Int64} + {b:Int64}",
                 params: [{"a", "2"}, {"b", "3"}]
               )

      assert rows == [[5]]
    end

    test "binds a String parameter containing a literal '?' with no misalignment", %{
      conn: conn
    } do
      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {q:String}",
                 params: [{"q", "is this a ? mark?"}]
               )

      assert rows == [["is this a ? mark?"]]
    end

    test "binds a String parameter containing quotes and backslashes", %{conn: conn} do
      value = ~S(O'Brien says "hi" \ back)

      assert {:ok, %{rows: rows}} =
               Connection.query(conn, "SELECT {s:String}", params: [{"s", value}])

      assert rows == [[value]]
    end

    test "binds an Array(UInt8) parameter", %{conn: conn} do
      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {a:Array(UInt8)}",
                 params: [{"a", "[1,2,3]"}]
               )

      assert rows == [[[1, 2, 3]]]
    end

    test "a parameter value never gets interpreted as SQL, proving real binding (not literal inlining)",
         %{conn: conn} do
      injection_attempt = "x'; DROP TABLE system.tables; --"

      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {s:String}",
                 params: [{"s", injection_attempt}]
               )

      assert rows == [[injection_attempt]]
    end

    test "raises the server's own type-mismatch error for a malformed value", %{conn: conn} do
      assert {:error, %ChDriver.Error{}} =
               Connection.query(conn, "SELECT {id:UInt64}", params: [{"id", "not a number"}])
    end
  end

  describe "Params.text/1" do
    test "renders common Elixir terms as ClickHouse literal text" do
      assert Params.text(5) == "5"
      assert Params.text(3.5) == "3.5"
      assert Params.text(true) == "1"
      assert Params.text(false) == "0"
      assert Params.text("hello") == "hello"
      assert Params.text(~D[2024-01-02]) == "2024-01-02"
      assert Params.text(~N[2024-01-02 03:04:05]) == "2024-01-02 03:04:05"
      assert Params.text([1, 2, 3]) == "[1,2,3]"
      assert Params.text(["a", "b"]) == "['a','b']"
    end

    test "round-trips a Decimal parameter live", %{conn: conn} do
      decimal = Decimal.new("3.140000000")

      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {d:Decimal64(9)}",
                 params: [{"d", Params.text(decimal)}]
               )

      assert [[result]] = rows
      assert Decimal.equal?(result, decimal)
    end

    test "round-trips a DateTime parameter live", %{conn: conn} do
      naive = ~N[2024-01-02 03:04:05]

      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {d:DateTime}",
                 params: [{"d", Params.text(naive)}]
               )

      assert [[result]] = rows
      assert NaiveDateTime.compare(result, naive) == :eq
    end

    test "round-trips an Array(String) parameter with embedded quotes/backslashes live", %{
      conn: conn
    } do
      list = ["O'Brien", "back\\slash"]

      assert {:ok, %{rows: rows}} =
               Connection.query(
                 conn,
                 "SELECT {a:Array(String)}",
                 params: [{"a", Params.text(list), Params.escape_rounds(list)}]
               )

      assert rows == [[list]]
    end

    test "escape_rounds/1 distinguishes lists from scalars" do
      assert Params.escape_rounds(["a", "b"]) == 1
      assert Params.escape_rounds([]) == 1
      assert Params.escape_rounds("plain string") == 2
      assert Params.escape_rounds(5) == 2
    end
  end
end
