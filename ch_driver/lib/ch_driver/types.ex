defmodule ChDriver.Types do
  @moduledoc """
  Parses ClickHouse column type strings, e.g. `"Nullable(String)"` or
  `"Map(String, Decimal(10, 2))"`, into their component parts.

  Pure string parsing — no wire decoding happens here. See
  `ChDriver.Protocol.Block.Wrappers` for how the parsed types drive actual
  column decoding.

  Supports `Nullable(T)`, `Array(T)`, `Map(K, V)`, `LowCardinality(T)`,
  `Decimal(P, S)` (and its `Decimal32/64/128/256(S)` aliases), and
  `FixedString(N)`. `Tuple(...)` isn't supported as a standalone column
  type — only as `Map`'s internal representation.
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
