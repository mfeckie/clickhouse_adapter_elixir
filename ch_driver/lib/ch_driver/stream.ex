defmodule ChDriver.Stream do
  @moduledoc """
  An `Enumerable` that lazily executes a query and yields its rows one
  ClickHouse wire-protocol Data block at a time, instead of buffering the
  whole result in memory the way `ChDriver.query/2,3,4` does.

  Built by `ChDriver.stream/2,3,4` -- see its docs for why `conn` must
  already be a checked-out `%DBConnection{}` (obtained via
  `DBConnection.run/3` or `DBConnection.transaction/3`), and for a usage
  example. All fields are private; this struct only exists so
  `defimpl Enumerable` below has something to dispatch on.

  Reducing over a `ChDriver.Stream` delegates straight to
  `DBConnection.reduce/3` via a plain `%DBConnection.Stream{}` (not
  `DBConnection.PrepareStream`) -- `query` is always a `%ChDriver.Query{}`
  struct, never a bare SQL string, so there's no separate "prepare first"
  path to distinguish the way `Postgrex.Stream`'s `Enumerable` impl does
  for its two possible `query` shapes (see `postgrex/lib/postgrex/stream.ex`).
  `DBConnection.reduce/3` drives `ChDriver.DBConnection.handle_declare/4`,
  `handle_fetch/4`, and `handle_deallocate/4` (see their docs) via
  `Stream.resource/3` under the hood, so cleanup (`handle_deallocate/4`)
  runs whether the consumer takes everything (`Enum.to_list/1`) or stops
  early (`Enum.take/2`, a `break` out of a `for`, an exception, ...).
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
