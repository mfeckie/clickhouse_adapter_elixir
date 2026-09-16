defmodule Ecto.Adapters.ClickHouse.DDLTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.ClickHouse.DDL
  alias Ecto.Adapters.ClickHouse.Migration
  alias Ecto.Migration.Table

  describe ":alias column DDL emission" do
    test "emits '<name> <type> ALIAS <expr>' with no Nullable(...) wrapping" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :status, Migration.enum8(pending: 0, active: 1, expired: 2),
         [alias: "multiIf(expired_at < now64(3), 'expired', 'active')"]}
      ]

      [sql] = DDL.execute_ddl({:create, table, commands})

      assert sql ==
               "CREATE TABLE \"assignments\" (\"id\" UInt64, \"status\" Enum8('pending' = 0, " <>
                 "'active' = 1, 'expired' = 2) ALIAS multiIf(expired_at < now64(3), 'expired', " <>
                 "'active')) ENGINE = MergeTree ORDER BY id"
    end

    test "skips the Nullable(...) wrapping even when :null is not given (the implicit default)" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :status, :string, [alias: "'active'"]}
      ]

      [sql] = DDL.execute_ddl({:create, table, commands})

      assert sql ==
               "CREATE TABLE \"assignments\" (\"status\" String ALIAS 'active') " <>
                 "ENGINE = MergeTree ORDER BY id"
    end

    test "skips the Nullable(...) wrapping when null: false is explicitly given" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :status, :string, [alias: "'active'", null: false]}
      ]

      [sql] = DDL.execute_ddl({:create, table, commands})

      assert sql ==
               "CREATE TABLE \"assignments\" (\"status\" String ALIAS 'active') " <>
                 "ENGINE = MergeTree ORDER BY id"
    end

    test "raises ArgumentError when :alias is combined with :default" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :status, :string, [alias: "'active'", default: "'pending'"]}
      ]

      assert_raise ArgumentError, ~r/can't combine :alias with :default/, fn ->
        DDL.execute_ddl({:create, table, commands})
      end
    end

    test "raises ArgumentError when :alias is combined with an explicit null: true" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :status, :string, [alias: "'active'", null: true]}
      ]

      assert_raise ArgumentError, ~r/can't combine :alias with null: true/, fn ->
        DDL.execute_ddl({:create, table, commands})
      end
    end

    test "raises ArgumentError when the :alias expression isn't a string" do
      table = %Table{name: :assignments, options: "ENGINE = MergeTree ORDER BY id"}

      commands = [
        {:add, :status, :string, [alias: :not_a_string]}
      ]

      assert_raise ArgumentError, ~r/must be a raw SQL expression string/, fn ->
        DDL.execute_ddl({:create, table, commands})
      end
    end
  end
end
