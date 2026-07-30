defmodule ChDriver.Error do
  @moduledoc """
  Represents a `DB::Exception` (or `DB::NetException`) returned by the
  server in an Exception packet (Server packet type 2).
  """
  defexception code: nil, name: nil, message: nil, stack_trace: nil, has_nested: false

  @impl true
  def message(%__MODULE__{name: name, message: msg, code: code}) do
    "#{name} (code #{code}): #{msg}"
  end
end
