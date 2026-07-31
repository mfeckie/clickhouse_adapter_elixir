defmodule ChDriver.Error do
  @moduledoc """
  Represents a `DB::Exception` (or `DB::NetException`) returned by the
  server in an Exception packet (Server packet type 2).
  """
  defexception code: nil,
               name: nil,
               message: nil,
               stack_trace: nil,
               has_nested: false,
               statement: nil

  @type t :: %__MODULE__{
          code: integer() | nil,
          name: String.t() | nil,
          message: String.t() | nil,
          stack_trace: String.t() | nil,
          has_nested: boolean(),
          statement: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{name: name, message: msg, code: code, statement: statement}) do
    base = "#{name} (code #{code}): #{msg}"

    case statement do
      nil -> base
      statement -> "#{base}\nQuery: #{statement}"
    end
  end
end
