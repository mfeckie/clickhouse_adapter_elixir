defmodule ChDriver.Query do
  @moduledoc """
  A query for `ChDriver.DBConnection` -- just a raw SQL string, optionally
  containing ClickHouse `{name:Type}` parameter placeholders.

  `params` passed to `DBConnection.execute/3,4` is a list of
  `{name, raw_text}` or `{name, raw_text, escape_rounds}` tuples bound via
  ClickHouse's native query-parameters mechanism -- see
  `ChDriver.Protocol.encode_query/2`, `ChDriver.Protocol.param_text/1`, and
  `ChDriver.Protocol.escape_rounds/1`.
  """
  defstruct [:statement, :query_id]

  @type t :: %__MODULE__{statement: binary, query_id: binary | nil}
end

defimpl DBConnection.Query, for: ChDriver.Query do
  @moduledoc """
  Trivial `DBConnection.Query` implementation: no server-side prepare
  exists in the ClickHouse native protocol for plain SQL text, so
  `parse/2` and `describe/2` are identity, `encode/3` passes params
  through unchanged (`ChDriver.DBConnection.handle_execute/4` is what
  actually binds them), and `decode/3` returns the `%ChDriver.Result{}`
  built by `ChDriver.DBConnection.handle_execute/4` unchanged.
  """

  def parse(query, _opts), do: query
  def describe(query, _opts), do: query
  def encode(_query, params, _opts), do: params
  def decode(_query, result, _opts), do: result
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
