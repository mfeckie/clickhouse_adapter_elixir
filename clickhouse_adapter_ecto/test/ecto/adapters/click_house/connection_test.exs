defmodule Ecto.Adapters.ClickHouse.ConnectionTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse.Connection

  describe "unfinished_delete_all?/2" do
    @delete_all ~s[ALTER TABLE "schema_migrations" DELETE WHERE ("version" = ?) SETTINGS mutations_sync = 2]
    @unfinished %ChDriver.Error{code: 341, name: "DB::Exception", message: "UNFINISHED"}

    test "is true for delete_all's mutation left unfinished by an inactive replica" do
      assert Connection.unfinished_delete_all?(@delete_all, @unfinished)
    end

    test "is false for any other error" do
      refute Connection.unfinished_delete_all?(@delete_all, %{@unfinished | code: 159})
      refute Connection.unfinished_delete_all?(@delete_all, %DBConnection.ConnectionError{})
    end

    test "is false for statements delete_all didn't generate" do
      refute Connection.unfinished_delete_all?(
               ~s[ALTER TABLE "t" DELETE WHERE 1 SETTINGS mutations_sync = 1],
               @unfinished
             )

      refute Connection.unfinished_delete_all?("OPTIMIZE TABLE t FINAL", @unfinished)
    end
  end
end
