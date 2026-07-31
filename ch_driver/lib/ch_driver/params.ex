defmodule ChDriver.Params do
  @moduledoc """
  Turns an Elixir value into a ClickHouse query parameter: the declared
  `{name:Type}` type name, the unquoted/unescaped literal text, and the
  wire-level escaping depth that text needs.

  This is the single place that mapping lives -- `ChDriver.Protocol`'s
  `encode_query/2` calls `text/1` and `escape_rounds/1` to build the wire
  bytes for a parameter's value, and
  `Ecto.Adapters.ClickHouse.Connection` calls `type/1` to build the
  matching `{name:Type}` placeholder text. Keeping both halves of the
  mapping in one module (rather than hand-synced across the two projects)
  is what guarantees a value's declared type and its rendered text always
  agree.
  """

  @doc """
  Turns an Elixir term into `{type, text, rounds}` in one call: the
  ClickHouse type name for its `{name:Type}` placeholder (see `type/1`),
  the literal text for its value (see `text/1`), and the escaping depth
  that text needs on the wire (see `escape_rounds/1`).
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
  Maps an Elixir runtime value to the ClickHouse type name used in its
  `{name:Type}` placeholder (e.g. `5 -> "Int64"`).

  There's no clause for `nil` -- see the moduledoc-adjacent note on
  `text/1` for why.
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
  Renders an Elixir term as the unquoted, unescaped ClickHouse literal
  text a query parameter's value should carry -- the same text you'd
  type after a `CAST(..., 'Type')` for that value. `ChDriver.Protocol`'s
  `encode_query/2` applies the wire-level quoting/escaping on top of this
  (see `quote_param_value/2`); this function only handles turning the
  value itself into ClickHouse literal syntax.

  There is no clause for `nil`: ClickHouse's query
  parameters have no type-independent way to express NULL (a
  `Nullable(String)`-typed NULL parameter fails to bind against, say, an
  `Int32` column), so callers should inline a literal `NULL` into the
  query text instead of routing `nil` through this.
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
  The number of backslash/quote-escaping rounds the wire encoder
  (`ChDriver.Protocol.encode_query/2`) must apply to bind `value` for it
  to round-trip -- `1` for a list (the `Array` literal text `text/1`
  renders for it already has its string elements `\\'`-escaped once, see
  `array_element_text/1`), `2` for everything else.

  The server unescapes a scalar parameter's value text *twice* before
  parsing it against the declared type, but only *once* for each string
  inside an `Array(String)`/`Map` value's already-quoted element syntax.
  A scalar value escaped only once loses backslashes asymmetrically (an
  odd leftover backslash fuses with the next character into an
  unintended escape, e.g. `\\b` becomes a backspace byte), while escaping
  it twice round-trips exactly. An `Array(String)` value escaped *twice*,
  on the other hand, corrupts its already-`\\'`-escaped elements, because
  the array parses each element with a single-escape "Quoted" reader,
  one level shallower than the plain scalar path
  (`ReplaceQueryParameterVisitor` re-parses a scalar's already-unescaped
  custom-setting value as escaped text a second time, but does not do so
  for array elements). This is undocumented ClickHouse behavior, treated
  here as a black-box wire fact rather than a designed feature.

  Takes the same Elixir term `text/1` would be called with, not its
  rendered text.
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
