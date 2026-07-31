defmodule ChDriver.Query do
  @moduledoc """
  A query for `ChDriver.DBConnection`: a raw SQL string, plus enough parsed
  state to bind parameters to it.

  `statement` can use plain `?` positional placeholders, or ClickHouse's own
  `{name:Type}` named placeholders written directly. Application code
  doesn't build this struct directly — pass a SQL string to
  `ChDriver.query/2,3,4` and it gets wrapped for you.

  Placeholder positions are lexed once (quote-aware, so a `?` inside a
  string literal is never mistaken for a bind position) and cached across
  repeated executions of the same prepared query, matching the shape of
  `Postgrex.Query`.
  """

  defstruct [:statement, :query_id, :param_names, :param_types, :segments]

  @type segment :: binary | :placeholder

  @type t :: %__MODULE__{
          statement: binary,
          query_id: binary | nil,
          param_names: [binary] | nil,
          param_types: [binary | nil] | nil,
          segments: [segment] | nil
        }

  @doc false
  # The one-time, quote-aware `?`-placeholder lexer. Returns an alternating
  # list of text chunks (binaries) and `:placeholder` markers, tracking
  # single/double-quoted regions so a literal `?` inside a string literal or
  # quoted identifier (e.g. a raw fragment's own text, or a `LIKE` pattern
  # written directly in the query) is never mistaken for a bind position.
  @spec lex_placeholders(binary) :: [segment]
  def lex_placeholders(sql) when is_binary(sql), do: lex_placeholders(sql, [], <<>>)

  defp lex_placeholders(<<>>, acc, buf), do: Enum.reverse([buf | acc])

  defp lex_placeholders(<<"?", rest::binary>>, acc, buf) do
    lex_placeholders(rest, [:placeholder, buf | acc], <<>>)
  end

  defp lex_placeholders(<<"'", rest::binary>>, acc, buf) do
    {quoted, rest} = consume_quoted(rest, ?', <<"'">>)
    lex_placeholders(rest, acc, <<buf::binary, quoted::binary>>)
  end

  defp lex_placeholders(<<"\"", rest::binary>>, acc, buf) do
    {quoted, rest} = consume_quoted(rest, ?", <<"\"">>)
    lex_placeholders(rest, acc, <<buf::binary, quoted::binary>>)
  end

  defp lex_placeholders(<<byte, rest::binary>>, acc, buf) do
    lex_placeholders(rest, acc, <<buf::binary, byte>>)
  end

  # `q` is the terminating quote byte (`?'` or `?"`); backslash-escapes are
  # honored the same way ClickHouse itself parses them (see
  # `ChDriver.Params.quote_param_value/2`) so an escaped quote never ends
  # the region early.
  defp consume_quoted(<<"\\", c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, "\\", c>>)
  end

  defp consume_quoted(<<c, rest::binary>>, q, acc) when c == q, do: {<<acc::binary, c>>, rest}

  defp consume_quoted(<<c, rest::binary>>, q, acc) do
    consume_quoted(rest, q, <<acc::binary, c>>)
  end

  defp consume_quoted(<<>>, _q, acc), do: {acc, <<>>}

  @doc false
  # Splices this call's `encode/3` output into the one-time-lexed
  # `segments`, producing the final SQL text (with `?`s replaced by
  # `{name:Type}` placeholders, or by a literal `NULL` for a `nil`-valued
  # position) and the final wire `:params` list
  # (`{name, raw_text, escape_rounds}`, exactly what
  # `ChDriver.Protocol.Messages.encode_query/2` already expects). Called
  # by `ChDriver.DBConnection.handle_execute/4`.
  @spec to_wire(t, list) :: {binary, [{binary, binary, 1 | 2}]}
  def to_wire(%__MODULE__{segments: segments}, encoded_params) do
    {sql_acc, wire_acc} = splice(segments, encoded_params, [], [])
    {IO.iodata_to_binary(sql_acc), wire_acc}
  end

  defp splice([], [], sql_acc, wire_acc) do
    {Enum.reverse(sql_acc), Enum.reverse(wire_acc)}
  end

  defp splice([text | rest], params, sql_acc, wire_acc) when is_binary(text) do
    splice(rest, params, [text | sql_acc], wire_acc)
  end

  defp splice([:placeholder | rest], [{_name, :null} | params_rest], sql_acc, wire_acc) do
    splice(rest, params_rest, ["NULL" | sql_acc], wire_acc)
  end

  defp splice(
         [:placeholder | rest],
         [{name, type, raw_text, rounds} | params_rest],
         sql_acc,
         wire_acc
       ) do
    placeholder = ["{", name, ":", type, "}"]
    splice(rest, params_rest, [placeholder | sql_acc], [{name, raw_text, rounds} | wire_acc])
  end
end

defimpl DBConnection.Query, for: ChDriver.Query do
  alias ChDriver.Params
  alias ChDriver.Query

  @moduledoc """
  `DBConnection.Query` implementation for `ChDriver.Query`.
  """

  @doc """
  Lexes `query.statement` for `?` placeholders and caches the result on the
  returned struct. Raises if called on a query that's already been parsed.
  """
  def parse(%Query{param_names: nil} = query, _opts) do
    segments = Query.lex_placeholders(query.statement)
    count = Enum.count(segments, &(&1 == :placeholder))
    param_names = for i <- 0..(count - 1)//1, do: "p#{i}"

    # `param_types` can't be resolved yet -- see the moduledoc -- but the
    # field still flips from the struct-wide `nil` sentinel ("not parsed
    # at all") to a same-length list of per-position `nil`s ("parsed;
    # types are resolved per-execution in `encode/3` instead"), so
    # `param_names`/`param_types`/`segments` all agree on whether this
    # query has been through `parse/2`.
    %{
      query
      | segments: segments,
        param_names: param_names,
        param_types: List.duplicate(nil, count)
    }
  end

  def parse(query, _opts) do
    raise ArgumentError, "query #{inspect(query)} has already been prepared"
  end

  @doc """
  Returns `query` unchanged. ClickHouse's native protocol has no
  server-side Describe step, so there's nothing to do here.
  """
  def describe(query, _opts), do: query

  @doc """
  Encodes `params` (the raw Elixir values for this call) against
  `query.param_names`.

  Raises `ArgumentError` on an arity mismatch or if `query` hasn't been
  parsed yet.
  """
  def encode(%Query{param_names: nil} = query, _params, _opts) do
    raise ArgumentError, "query #{inspect(query)} has not been prepared"
  end

  def encode(%Query{param_names: names} = query, params, _opts)
      when length(names) != length(params) do
    raise ArgumentError,
          "parameters must be of length #{length(names)} for query #{inspect(query)}, got " <>
            "#{length(params)}"
  end

  def encode(%Query{param_names: names}, params, _opts) do
    names
    |> Enum.zip(params)
    |> Enum.map(fn
      {name, nil} -> {name, :null}
      {name, value} -> Tuple.insert_at(Params.encode(value), 0, name)
    end)
  end

  @doc """
  Builds a `%ChDriver.Result{}` from the `{columns, rows}` map
  `ChDriver.DBConnection`'s `handle_execute/4` returns, honoring
  `opts[:decode_mapper]` (a function applied to each decoded row) exactly
  like `Postgrex.Query.decode/3` does.
  """
  def decode(_query, %{columns: columns, rows: rows}, opts) do
    rows =
      case opts[:decode_mapper] do
        nil -> rows
        mapper -> Enum.map(rows, mapper)
      end

    %ChDriver.Result{columns: columns, rows: rows, num_rows: length(rows)}
  end
end

defimpl String.Chars, for: ChDriver.Query do
  @moduledoc false
  # Callers that log or interpolate a query need this -- e.g.
  # `Ecto.Adapters.SQL.log/5` calls `to_string/1` on the cached query when
  # emitting `[:ecto_adapter, :query]` telemetry log entries; without this
  # `ChDriver.Query` has no `String.Chars` implementation and every
  # successful query raises (harmlessly, but noisily -- the query itself
  # already succeeded by the time logging runs) a `Protocol.UndefinedError`
  # from inside the logging callback.
  def to_string(%ChDriver.Query{statement: statement}), do: statement
end
