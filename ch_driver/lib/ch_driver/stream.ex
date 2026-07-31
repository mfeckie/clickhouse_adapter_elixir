defmodule ChDriver.Stream do
  @moduledoc """
  An `Enumerable` that streams a query's rows one wire-protocol block at a
  time, instead of loading the whole result into memory.

  Built by `ChDriver.stream/2,3,4` — see its docs for a usage example. All
  fields are private.

  Cleanup runs whether the consumer takes everything (`Enum.to_list/1`) or
  stops early (`Enum.take/2`, a `break`, a raised exception, ...) — the
  underlying query gets cancelled properly either way.
  """
  @derive {Inspect, only: []}
  defstruct [:conn, :query, :params, :opts]

  @type t :: %__MODULE__{
          conn: DBConnection.conn(),
          query: ChDriver.Query.t(),
          params: list,
          opts: keyword
        }
end

defimpl Enumerable, for: ChDriver.Stream do
  alias ChDriver.Stream, as: ChStream

  def reduce(%ChStream{conn: conn, query: query, params: params, opts: opts}, acc, fun) do
    stream = %DBConnection.Stream{conn: conn, query: query, params: params, opts: opts}
    DBConnection.reduce(stream, acc, fun)
  end

  def member?(_stream, _element), do: {:error, __MODULE__}

  def count(_stream), do: {:error, __MODULE__}

  def slice(_stream), do: {:error, __MODULE__}
end
