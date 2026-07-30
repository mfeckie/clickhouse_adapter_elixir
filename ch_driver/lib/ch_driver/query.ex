defmodule ChDriver.Query do
  @moduledoc """
  A query for `ChDriver.DBConnection` -- currently just a raw SQL string.

  ClickHouse native-protocol parameterization (query_parameters, gated on
  `DBMS_MIN_PROTOCOL_VERSION_WITH_PARAMETERS` and already sent-but-empty by
  `ChDriver.Protocol.encode_query/2`) is not implemented yet; `params`
  passed to `DBConnection.execute/3,4` are accepted but ignored -- callers
  must interpolate values into `statement` themselves for now.
  """
  defstruct [:statement, :query_id]

  @type t :: %__MODULE__{statement: binary, query_id: binary | nil}
end

defimpl DBConnection.Query, for: ChDriver.Query do
  @moduledoc """
  Trivial `DBConnection.Query` implementation: no server-side prepare
  exists in the ClickHouse native protocol for plain SQL text, so
  `parse/2` and `describe/2` are identity, `encode/3` passes params through
  unchanged (unused today -- see `ChDriver.Query`'s moduledoc), and
  `decode/3` returns the `%ChDriver.Result{}` built by
  `ChDriver.DBConnection.handle_execute/4` unchanged.
  """

  def parse(query, _opts), do: query
  def describe(query, _opts), do: query
  def encode(_query, params, _opts), do: params
  def decode(_query, result, _opts), do: result
end
