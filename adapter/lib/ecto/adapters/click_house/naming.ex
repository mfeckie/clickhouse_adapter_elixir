defmodule Ecto.Adapters.ClickHouse.Naming do
  @moduledoc """
  Quoting -- double quotes are
  accepted for identifiers (`SELECT "id" FROM "events"`); backticks work
  too, but double quotes are the ANSI-standard choice and match what the
  rest of the Ecto ecosystem (Postgres) expects, so that's what's used
  here. Single quotes remain reserved for string literals.

  `quote_name/1` and `quote_table/2` are exposed (rather than kept `defp`)
  so `Ecto.Adapters.ClickHouse.DDL`'s DDL generation, `Ecto.Adapters.ClickHouse.QueryBuilder`,
  and `Ecto.Adapters.ClickHouse.Expression` can all reuse the exact same
  identifier-quoting logic, instead of duplicating it.
  """

  ## Query generation (SELECT) naming helpers

  @doc false
  def create_names(%{sources: sources}, as_prefix) do
    create_names(sources, 0, tuple_size(sources), as_prefix) |> List.to_tuple()
  end

  @doc false
  def create_names(sources, pos, limit, as_prefix) when pos < limit do
    [create_name(sources, pos, as_prefix) | create_names(sources, pos + 1, limit, as_prefix)]
  end

  def create_names(_sources, pos, pos, as_prefix), do: [as_prefix]

  defp create_name(sources, pos, as_prefix) do
    case elem(sources, pos) do
      {table, schema, prefix} ->
        name = as_prefix ++ [create_alias(table) | Integer.to_string(pos)]
        {quote_table(prefix, table), name, schema}

      %Ecto.SubQuery{} ->
        {nil, as_prefix ++ [?s | Integer.to_string(pos)], nil}
    end
  end

  @doc false
  def create_alias(<<first, _rest::binary>>) when first in ?a..?z when first in ?A..?Z, do: first
  def create_alias(_), do: ?t

  ## Quoting

  @doc false
  def quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  def quote_name(name) when is_binary(name) do
    if String.contains?(name, "\"") do
      error!(nil, "bad literal/field/table name #{inspect(name)} (\" is not permitted)")
    end

    [?", name, ?"]
  end

  @doc false
  def quote_names(names), do: Enum.map_intersperse(names, ?,, &quote_name/1)

  @doc false
  def quote_table(nil, name), do: quote_table(name)
  def quote_table(prefix, name), do: [quote_table(prefix), ?., quote_table(name)]

  defp quote_table(name) when is_atom(name), do: quote_table(Atom.to_string(name))

  defp quote_table(name) do
    if String.contains?(name, "\"") do
      error!(nil, "bad table name #{inspect(name)}")
    end

    [?", name, ?"]
  end

  @doc false
  def error!(nil, message), do: raise(ArgumentError, message)
  def error!(query, message), do: raise(Ecto.QueryError, query: query, message: message)
end
