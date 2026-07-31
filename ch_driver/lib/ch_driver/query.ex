defmodule ChDriver.Query do
  @moduledoc """
  A query for `ChDriver.DBConnection` -- a raw SQL string, optionally
  containing `?` positional placeholders (rewritten by `parse/2` into
  ClickHouse native `{name:Type}` parameter placeholders at execute time)
  or literal `{name:Type}` placeholders written directly by the caller.

  `params` passed to `DBConnection.execute/3,4` is the list of raw Elixir
  values to bind, in the same order the `?`s appear in `statement`.
  `DBConnection.Query.parse/2` (see the `defimpl` below) lexes `statement`
  for `?` placeholders exactly once -- the result is cached by
  `DBConnection`/`Ecto.Adapters.SQL`'s own query cache across repeated
  executions of the same prepared query, so this quote-aware scan happens
  once per distinct query shape rather than on every execute.

  ## Why `param_types` can't be baked in at parse time

  ClickHouse's native protocol has no untyped placeholder syntax -- every
  bound parameter must be written as `{name:Type}` with a concrete type,
  and a `nil` value can't be bound as a typed parameter at all (see
  `ChDriver.Params`'s moduledoc): it has to be inlined as the literal
  `NULL` token instead. Both the concrete type and the nil-ness of a value
  are properties of *this call's actual arguments*, which `parse/2` never
  sees (`DBConnection.Query.parse/2` runs before any params exist -- see
  `DBConnection.prepare_execute/4`'s implementation). Two executions of
  the very same cached/prepared query can legitimately bind different
  shapes at the same position -- e.g. `Repo.insert!/1` on a schema with a
  nullable column, called once with a value and once with `nil` for that
  column, reuses the identical cached insert statement both times.

  So `parse/2` only resolves *where* the placeholders are (the expensive,
  quote-aware part) and stores that as `segments`; `encode/3` resolves
  *what* to bind each execution's actual values as (via
  `ChDriver.Params.encode/1`, cheap and per-value); and
  `ChDriver.DBConnection.handle_execute/4` splices the two together into
  the final wire statement + wire params for this specific call. This
  keeps the expensive one-time lexing cached while still allowing a
  per-execution decision between a typed placeholder and an inlined
  `NULL` literal at any given position.
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
  See `ChDriver.Query`'s moduledoc for the full rationale, in particular
  for why type resolution is deliberately *not* done in `parse/2`.
  """

  @doc """
  Lexes `query.statement` for `?` placeholders exactly once and caches the
  result (`segments`, `param_names`, `param_types`) on the returned
  struct. Raises if called again on an already-parsed query -- mirrors
  `Postgrex.Query`'s `parse/2` (see `postgrex/lib/postgrex/query.ex`),
  which exists to catch a caller accidentally re-preparing a query struct
  that DBConnection's own cache should have prevented from reaching
  `parse/2` a second time.
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
  Identity. ClickHouse's native protocol has no server-side Describe --
  there is no request/response pair to send after Prepare the way
  postgres's Parse/Describe/Bind flow has one. `handle_prepare/2` in
  `ChDriver.DBConnection` is (and will remain) `{:ok, query, state}` for
  the same reason: there is nothing for either callback to do here. This
  is intentionally a no-op, not a gap -- do not "fix" it by adding a
  network round-trip.
  """
  def describe(query, _opts), do: query

  @doc """
  Encodes `params` (the raw Elixir values for this call) against
  `query.param_names`, raising `ArgumentError` on an arity mismatch or on
  an unparsed query -- mirrors `Postgrex.Query.encode/3`
  (`postgrex/lib/postgrex/query.ex:66-79`).

  Each element of the returned list is either `{name, :null}` (the value
  was `nil`; `ChDriver.Query.to_wire/2` inlines this as a literal `NULL`
  rather than a typed placeholder -- see `ChDriver.Params`'s moduledoc for
  why nil can't be bound as a typed parameter) or
  `{name, type, raw_text, escape_rounds}` from `ChDriver.Params.encode/1`.
  `ChDriver.DBConnection.handle_execute/4` is what turns this into the
  final wire statement/params via `ChDriver.Query.to_wire/2`.
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
  `ChDriver.DBConnection.handle_execute/4` returns, honoring
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
