defmodule ChDriver.TypesTest do
  @moduledoc """
  Direct unit coverage for `ChDriver.Types`'s type-string parser -- pure
  string parsing, decoupled from the wire-decoding integration tests
  elsewhere in this suite. Particular attention to `split_top_level_comma/1`,
  the paren-depth scanner behind `parse_map/1`, which previously had no
  direct test surface at all (it only ran indirectly via
  `ChDriver.Protocol.NativeBlock.decode_column_data/3`).
  """

  use ExUnit.Case, async: true

  alias ChDriver.Types

  describe "strip_wrapper/2" do
    test "strips a matching prefix and trailing paren" do
      assert Types.strip_wrapper("Nullable(String)", "Nullable(") == {:ok, "String"}
    end

    test "preserves a parameterized inner type verbatim" do
      assert Types.strip_wrapper("Nullable(DateTime(3))", "Nullable(") == {:ok, "DateTime(3)"}
    end

    test "errors when the prefix doesn't match" do
      assert Types.strip_wrapper("Array(String)", "Nullable(") == :error
    end

    test "returns an empty inner string for an empty wrapper" do
      # byte_size(rest) > 0 in the guard only excludes the case where there
      # is nothing at all after the prefix (not even the closing paren) --
      # "Nullable()" still has one byte of `rest` (")"), so this succeeds
      # with an empty inner type rather than erroring.
      assert Types.strip_wrapper("Nullable()", "Nullable(") == {:ok, ""}
    end
  end

  describe "parse_nullable/1" do
    test "parses a simple inner type" do
      assert Types.parse_nullable("Nullable(UInt32)") == {:ok, "UInt32"}
    end

    test "errors for a non-Nullable type" do
      assert Types.parse_nullable("UInt32") == :error
    end
  end

  describe "parse_array/1" do
    test "parses a simple inner type" do
      assert Types.parse_array("Array(String)") == {:ok, "String"}
    end

    test "parses a nested wrapper inner type" do
      assert Types.parse_array("Array(Nullable(String))") == {:ok, "Nullable(String)"}
    end
  end

  describe "parse_low_cardinality/1" do
    test "parses a simple inner type" do
      assert Types.parse_low_cardinality("LowCardinality(String)") == {:ok, "String"}
    end
  end

  describe "split_top_level_comma/1" do
    test "splits a simple two-part list" do
      assert Types.split_top_level_comma("String, UInt32") == ["String", " UInt32"]
    end

    test "does not split on a comma nested inside a parameterized inner type" do
      assert Types.split_top_level_comma("String, Decimal(10, 2)") ==
               ["String", " Decimal(10, 2)"]
    end

    test "handles multiple levels of nested parens" do
      assert Types.split_top_level_comma("Array(Map(String, UInt32)), String") ==
               ["Array(Map(String, UInt32))", " String"]
    end

    test "returns a single-element list when there is no top-level comma" do
      assert Types.split_top_level_comma("String") == ["String"]
    end

    test "errors on unbalanced parens" do
      assert Types.split_top_level_comma("String, Decimal(10, 2") == :error
    end
  end

  describe "parse_map/1" do
    test "parses a simple key/value pair" do
      assert Types.parse_map("Map(String, UInt32)") == {:ok, "String", "UInt32"}
    end

    test "parses a value type containing its own top-level comma" do
      assert Types.parse_map("Map(String, Decimal(10, 2))") == {:ok, "String", "Decimal(10, 2)"}
    end

    test "trims whitespace around key/value types" do
      assert Types.parse_map("Map(String,   UInt32)") == {:ok, "String", "UInt32"}
    end

    test "errors for a non-Map type" do
      assert Types.parse_map("Array(String)") == :error
    end
  end

  describe "parse_fixed_string/1" do
    test "parses the byte size" do
      assert Types.parse_fixed_string("FixedString(16)") == {:ok, 16}
    end

    test "errors for a malformed size" do
      assert Types.parse_fixed_string("FixedString(abc)") == :error
    end

    test "errors for a non-FixedString type" do
      assert Types.parse_fixed_string("String") == :error
    end
  end

  describe "parse_decimal/1" do
    test "parses explicit precision and scale" do
      assert Types.parse_decimal("Decimal(10, 2)") == {:ok, 10, 2}
    end

    test "parses the Decimal32/64/128/256 fixed-precision aliases" do
      assert Types.parse_decimal("Decimal32(4)") == {:ok, 9, 4}
      assert Types.parse_decimal("Decimal64(4)") == {:ok, 18, 4}
      assert Types.parse_decimal("Decimal128(4)") == {:ok, 38, 4}
      assert Types.parse_decimal("Decimal256(4)") == {:ok, 76, 4}
    end

    test "errors for a non-Decimal type" do
      assert Types.parse_decimal("UInt32") == :error
    end
  end

  describe "parse_variant/1" do
    test "parses the alternatives in type-name order" do
      assert Types.parse_variant("Variant(Bool, Int32, String)") ==
               {:ok, ["Bool", "Int32", "String"]}
    end

    test "does not split a parameterized alternative on its own comma" do
      assert Types.parse_variant("Variant(Int32, Decimal(10, 2))") ==
               {:ok, ["Int32", "Decimal(10, 2)"]}
    end

    test "parses a nested wrapper alternative verbatim" do
      assert Types.parse_variant("Variant(Array(UInt8), LowCardinality(String))") ==
               {:ok, ["Array(UInt8)", "LowCardinality(String)"]}
    end

    test "parses a single-alternative Variant" do
      assert Types.parse_variant("Variant(String)") == {:ok, ["String"]}
    end

    test "errors for a non-Variant type" do
      assert Types.parse_variant("Nullable(String)") == :error
    end
  end

  describe "parse_tuple/1" do
    test "parses the element types in wire order" do
      assert Types.parse_tuple("Tuple(Int32, String)") == {:ok, ["Int32", "String"]}
    end

    test "strips element names" do
      assert Types.parse_tuple("Tuple(a Int32, b String)") == {:ok, ["Int32", "String"]}
    end

    test "does not split a parameterized element on its own comma" do
      assert Types.parse_tuple("Tuple(Int32, Map(String, Int32))") ==
               {:ok, ["Int32", "Map(String, Int32)"]}
    end

    test "keeps a parameterized element whose args contain a space intact" do
      # The space here is inside the type's own arguments, not a name.
      assert Types.parse_tuple("Tuple(Decimal(10, 2), String)") ==
               {:ok, ["Decimal(10, 2)", "String"]}
    end

    test "strips a name from a parameterized element" do
      assert Types.parse_tuple("Tuple(amount Decimal(10, 2), label String)") ==
               {:ok, ["Decimal(10, 2)", "String"]}
    end

    test "parses a nested wrapper element verbatim" do
      assert Types.parse_tuple("Tuple(Array(LowCardinality(String)), String)") ==
               {:ok, ["Array(LowCardinality(String))", "String"]}
    end

    test "parses a single-element Tuple" do
      assert Types.parse_tuple("Tuple(String)") == {:ok, ["String"]}
    end

    test "errors for a non-Tuple type" do
      assert Types.parse_tuple("Nullable(String)") == :error
    end
  end

  describe "parse_datetime64/1" do
    test "parses the precision" do
      assert Types.parse_datetime64("DateTime64(3)") == {:ok, 3}
      assert Types.parse_datetime64("DateTime64(0)") == {:ok, 0}
      assert Types.parse_datetime64("DateTime64(9)") == {:ok, 9}
    end

    test "ignores the timezone argument, which doesn't affect the stored ticks" do
      assert Types.parse_datetime64("DateTime64(3, 'Europe/London')") == {:ok, 3}
      assert Types.parse_datetime64("DateTime64(6,'UTC')") == {:ok, 6}
    end

    test "errors for second-precision DateTime, which has its own codec" do
      assert Types.parse_datetime64("DateTime") == :error
      assert Types.parse_datetime64("DateTime('UTC')") == :error
    end

    test "errors for a malformed precision" do
      assert Types.parse_datetime64("DateTime64(abc)") == :error
    end
  end
end
