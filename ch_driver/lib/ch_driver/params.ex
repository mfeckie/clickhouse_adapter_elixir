defmodule ChDriver.Params do
  @moduledoc """
  Converts Elixir values into ClickHouse query parameters.

  Every bound query parameter needs three things: a ClickHouse type name
  for its `{name:Type}` placeholder, the literal text of its value, and how
  many rounds of escaping that text needs on the wire. `type/1`, `text/1`,
  and `escape_rounds/1` produce each of those from a plain Elixir value;
  `encode/1` returns all three at once.

  `nil` isn't supported here — see `text/1`'s docs.
  """

  @doc """
  Encodes `term` as `{type, text, rounds}` — the ClickHouse type name for
  its `{name:Type}` placeholder (see `type/1`), the literal text for its
  value (see `text/1`), and the escaping depth that text needs on the wire
  (see `escape_rounds/1`).
  """
  @spec encode(term) :: {binary, binary, 1 | 2}
  def encode(term) do
    {type(term), text(term), escape_rounds(term)}
  end

  # Maps an Elixir runtime value to the ClickHouse type name used in its
  # `{name:Type}` placeholder. There's no clause for `nil` -- callers
  # inline it as a literal `NULL` instead of routing it through here,
  # since no single declared parameter type parses NULL correctly against
  # every column type it might be compared against (a `Nullable(String)`
  # NULL parameter fails to bind against an `Int32` column with "Attempt
  # to read after eof... while converting '' to Int32").
  @doc """
  Maps an Elixir value to the ClickHouse type name for its `{name:Type}`
  placeholder, e.g. `5 -> "Int64"`, `"hi" -> "String"`.

  Raises `ArgumentError` for `nil` and for any type this driver doesn't
  know how to bind — see `text/1` for why `nil` isn't supported.
  """
  @spec type(term) :: binary
  def type(b) when is_binary(b), do: "String"
  def type(i) when is_integer(i), do: "Int64"
  def type(f) when is_float(f), do: "Float64"
  def type(bool) when is_boolean(bool), do: "UInt8"
  def type(%Decimal{}), do: "String"
  def type(%Date{}), do: "Date"
  def type(%NaiveDateTime{}), do: "DateTime"
  def type(%DateTime{}), do: "DateTime"
  def type([]), do: "Array(String)"
  def type([head | _]), do: "Array(#{type(head)})"

  def type(other) do
    raise ArgumentError,
          "the ClickHouse adapter does not know how to bind #{inspect(other)} as a query " <>
            "parameter"
  end

  @doc """
  Renders an Elixir term as ClickHouse literal text — the same text you'd
  write after `CAST(..., 'Type')` for that value, unquoted and unescaped.

  There's no clause for `nil`: ClickHouse query parameters have no
  type-independent way to express NULL. If your value can be `nil`, inline
  a literal `NULL` into the query text yourself instead of binding it as a
  parameter.
  """
  @spec text(term) :: binary
  def text(b) when is_binary(b), do: b
  def text(i) when is_integer(i), do: Integer.to_string(i)
  def text(f) when is_float(f), do: Float.to_string(f)
  def text(true), do: "1"
  def text(false), do: "0"
  def text(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def text(%Date{} = d), do: Date.to_string(d)
  def text(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_string(ndt)

  # DateTime.to_string/1 appends a "Z"/offset suffix that ClickHouse's
  # DateTime literal parser rejects outright -- only a UTC DateTime maps
  # unambiguously onto ClickHouse's own offset-less DateTime type (same
  # reasoning as `type/1`'s DateTime clause).
  def text(%DateTime{utc_offset: 0, std_offset: 0} = dt) do
    dt |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end

  def text(%DateTime{} = dt) do
    raise ArgumentError,
          "only UTC DateTime values can be bound as a ClickHouse query parameter " <>
            "(ClickHouse's DateTime column type has no offset of its own), got #{inspect(dt)}"
  end

  # ClickHouse's `Array(T)` literal syntax (`[elem1, elem2, ...]`), with
  # string elements individually quoted/escaped the same way the wire
  # layer quotes the parameter as a whole. An `Array(String)` parameter
  # value must already contain valid `['a', 'b']`-style syntax *before*
  # the outer wire-level quoting is applied, not a bare comma-joined list.
  def text(list) when is_list(list) do
    IO.iodata_to_binary([?[, Enum.map_intersperse(list, ?,, &array_element_text/1), ?]])
  end

  def text(other) do
    raise ArgumentError,
          "don't know how to bind #{inspect(other)} as a ClickHouse query parameter"
  end

  @doc """
  How many rounds of backslash/quote escaping `value`'s bound text needs
  to round-trip through ClickHouse correctly: `1` for a list, `2` for
  everything else.

  Takes the same Elixir term you'd pass to `text/1`, not its rendered text.
  See `ChDriver.Query`'s wire encoding for where this gets applied — the
  two escaping depths aren't arbitrary, they match how ClickHouse's server
  actually unescapes scalar values vs. array elements (see
  `ARCHITECTURE.md` if you're curious why).
  """
  @spec escape_rounds(term) :: 1 | 2
  def escape_rounds(list) when is_list(list), do: 1
  def escape_rounds(_other), do: 2

  @doc false
  # Called by `ChDriver.Protocol.encode_one_param/3` to apply the
  # wire-level single-quoting/escaping on top of `text/1`'s rendered
  # literal text -- kept here (rather than duplicated in `Protocol`)
  # since it shares `escape_once/1` with `array_element_text/1` below.
  @spec quote_param_value(binary, 1 | 2) :: binary
  def quote_param_value(raw_text, rounds) do
    escaped = Enum.reduce(1..rounds, raw_text, fn _, acc -> escape_once(acc) end)
    <<?', escaped::binary, ?'>>
  end

  defp escape_once(bin) do
    bin
    |> :binary.replace("\\", "\\\\", [:global])
    |> :binary.replace("'", "\\'", [:global])
  end

  defp array_element_text(b) when is_binary(b) do
    escaped =
      b
      |> :binary.replace("\\", "\\\\", [:global])
      |> :binary.replace("'", "\\'", [:global])

    <<?', escaped::binary, ?'>>
  end

  defp array_element_text(other), do: text(other)
end
