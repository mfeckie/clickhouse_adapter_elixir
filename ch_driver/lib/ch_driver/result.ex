defmodule ChDriver.Result do
  @moduledoc """
  The result of executing a `ChDriver.Query`, returned from
  `DBConnection.execute/3,4` via `ChDriver.query/2,3`.
  """
  defstruct columns: [], rows: [], num_rows: 0

  @type t :: %__MODULE__{
          columns: [{binary, binary}],
          rows: [[term]],
          num_rows: non_neg_integer
        }
end
