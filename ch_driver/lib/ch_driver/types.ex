defmodule ChDriver.Types do
  @moduledoc """
  Parses ClickHouse's column *type strings* (e.g. `"Nullable(String)"`,
  `"Map(String, Decimal(10, 2))"`) into their component parts. Pure string
  parsing only -- no wire decoding happens here; see
  `ChDriver.Types.Registry` for the scalar codec table and
  `ChDriver.Protocol.Block.Wrappers` / `ChDriver.Protocol.Block.Sparse` for
  how these parsed types drive decoding of wrapper/compound column data.

  Every wrapper/compound type ClickHouse's Native block format can send
  that this driver understands is recognized here:

    * `Nullable(T)` -- decoded in `ChDriver.Protocol.Block.Wrappers`, whose
      moduledoc documents the null-map wire format.
    * `Array(T)` -- decoded in `ChDriver.Protocol.Block.Wrappers`, whose
      moduledoc documents the offsets wire format.
    * `Map(K, V)` -- decoded in `ChDriver.Protocol.Block.Wrappers`. Parsing
      it here requires finding the *top-level* comma only (tracking paren
      depth via `split_top_level_comma/1`), so e.g.
      `Map(String, Decimal(10, 2))` isn't split on the inner comma.
    * `LowCardinality(T)` -- decoded in `ChDriver.Protocol.Block.Wrappers`.
    * `Decimal(P, S)` and its fixed-precision aliases `Decimal32(S)` /
      `Decimal64(S)` / `Decimal128(S)` / `Decimal256(S)` -- decoded in
      `ChDriver.Protocol.Block.Wrappers`.
    * `FixedString(N)` -- decoded via the generic
      `ChDriver.Types.Registry.decode_fixed_width/4` with an identity
      unpack function (see the call site in
      `ChDriver.Protocol.NativeBlock`'s `decode_column_data/3`).

  `Tuple(...)` is not supported in its own right -- only as `Map(K, V)`'s
  implicit internal representation, not as a directly-selectable column
  type (see `ChDriver.Protocol.Block.Wrappers`'s `decode_map/4` moduledoc for
  why generalizing it is more work than it looks).
  """

  @doc """
  Strips a `Prefix(...)` wrapper down to its inner contents, given the
  exact `"Prefix("` (including the opening paren) to match against. Not a
  general parenthesis-balancer -- just strips the given prefix and the
  trailing `)` -- but that's sufficient even for a parameterized inner
  type like `Nullable(DateTime(3))`, since the outer `)` is always the
  last byte of the whole type string.
  """
  def strip_wrapper(type, prefix) do
    prefix_size = byte_size(prefix)

    case type do
      <<^prefix::binary-size(prefix_size), rest::binary>> when byte_size(rest) > 0 ->
        case String.split_at(rest, byte_size(rest) - 1) do
          {inner, ")"} -> {:ok, inner}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Parses ClickHouse's `Nullable(T)` wrapper syntax, returning the inner
  type string.
  """
  def parse_nullable(type), do: strip_wrapper(type, "Nullable(")

  @doc """
  Parses ClickHouse's `Array(T)` wrapper syntax, returning the inner type
  string.
  """
  def parse_array(type), do: strip_wrapper(type, "Array(")

  @doc """
  Parses ClickHouse's `LowCardinality(T)` wrapper syntax, returning the
  inner type string.
  """
  def parse_low_cardinality(type), do: strip_wrapper(type, "LowCardinality(")

  @doc """
  Parses ClickHouse's `Map(K, V)` wrapper syntax, returning `{:ok,
  key_type, value_type}`. Splits on the top-level comma only (tracking
  paren depth so e.g. `Map(String, Decimal(10, 2))` isn't split on the
  inner comma).
  """
  def parse_map(type) do
    with {:ok, inner} <- strip_wrapper(type, "Map("),
         [key_type, value_type] <- split_top_level_comma(inner) do
      {:ok, String.trim(key_type), String.trim(value_type)}
    else
      _ -> :error
    end
  end

  @doc """
  Splits `inner` on its top-level comma(s) only, tracking paren depth so a
  parameterized inner type's own comma (e.g. the `Decimal(10, 2)` inside
  `Map(String, Decimal(10, 2))`) is never mistaken for the wrapper's own
  separator. Returns the list of (untrimmed) parts, or `:error` if the
  parens are unbalanced.
  """
  def split_top_level_comma(inner) do
    inner
    |> String.to_charlist()
    |> do_split_top_level_comma(0, [], [])
  end

  defp do_split_top_level_comma([], 0, current, acc) do
    Enum.reverse([current |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split_top_level_comma([], _depth, _current, _acc), do: :error

  defp do_split_top_level_comma([?( | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth + 1, [?( | current], acc)
  end

  defp do_split_top_level_comma([?) | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth - 1, [?) | current], acc)
  end

  defp do_split_top_level_comma([?, | rest], 0, current, acc) do
    do_split_top_level_comma(rest, 0, [], [current |> Enum.reverse() |> List.to_string() | acc])
  end

  defp do_split_top_level_comma([char | rest], depth, current, acc) do
    do_split_top_level_comma(rest, depth, [char | current], acc)
  end

  @doc "Parses ClickHouse's `FixedString(N)` type, returning `{:ok, n}`."
  def parse_fixed_string("FixedString(" <> rest) do
    case Regex.run(~r/^(\d+)\)$/, rest) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_fixed_string(_type), do: :error

  @doc """
  Parses `Decimal(P, S)` and the `Decimal32(S)`/`Decimal64(S)`/
  `Decimal128(S)`/`Decimal256(S)` fixed-precision aliases, returning
  `{:ok, precision, scale}`.
  """
  def parse_decimal("Decimal(" <> rest) do
    case Regex.run(~r/^(\d+)\s*,\s*(\d+)\)$/, rest) do
      [_, precision, scale] -> {:ok, String.to_integer(precision), String.to_integer(scale)}
      nil -> :error
    end
  end

  def parse_decimal("Decimal32(" <> rest), do: parse_decimal_alias(rest, 9)
  def parse_decimal("Decimal64(" <> rest), do: parse_decimal_alias(rest, 18)
  def parse_decimal("Decimal128(" <> rest), do: parse_decimal_alias(rest, 38)
  def parse_decimal("Decimal256(" <> rest), do: parse_decimal_alias(rest, 76)
  def parse_decimal(_type), do: :error

  defp parse_decimal_alias(rest, precision) do
    case Regex.run(~r/^(\d+)\)$/, rest) do
      [_, scale] -> {:ok, precision, String.to_integer(scale)}
      nil -> :error
    end
  end
end
