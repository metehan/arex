defmodule Arex.Command do
  @moduledoc """
  Write-oriented raw command helpers.

  Use this module for ArcadeDB commands that are not naturally modeled by the
  higher-level `Arex.Record`, `Arex.Schema`, `Arex.Vertex`, or `Arex.Edge`
  helpers.

  Results are normalized to `%{count: ..., records: ...}` so application code
  can handle common command shapes consistently even when ArcadeDB returns
  slightly different response bodies.

  Use `Arex.Command` when you want explicit write statements and still want:

  - Arex option resolution
  - normalized error tuples
  - stable result normalization
  - explicit control over SQL versus SQLScript

  If a write maps cleanly to a higher-level helper, prefer that helper first.
  """

  alias Arex.Http

  @doc """
  Executes a raw command using the resolved language.

  The return value is normalized to `%{count: ..., records: ...}` so callers can
  handle common command shapes consistently.

  Use this when you want the command language to come from resolved options
  rather than forcing `sql` or `sqlscript` explicitly.
  """
  def run(statement, params \\ %{}, opts \\ []) do
    with {:ok, result} <- Http.command_raw(statement, params, opts) do
      {:ok, normalize_result(result)}
    end
  end

  @doc """
  Executes a SQL command.

  This helper always forces `language: "sql"` regardless of any configured
  default language.
  """
  def sql(statement, params \\ %{}, opts \\ []) do
    run(statement, params, put_language(opts, "sql"))
  end

  @doc """
  Executes a SQLScript command.

  Use this for multi-step write flows, explicit transactional scripts, or other
  SQLScript-only features.
  """
  def sqlscript(statement, params \\ %{}, opts \\ []) do
    run(statement, params, put_language(opts, "sqlscript"))
  end

  defp normalize_result(result) do
    %{
      count: infer_count(result),
      records: infer_records(result)
    }
  end

  defp infer_count(result) when is_integer(result), do: result
  defp infer_count([count]) when is_integer(count), do: count

  defp infer_count(result) when is_list(result) do
    if Enum.all?(result, &(is_map(&1) and is_integer(&1["count"]))) do
      Enum.reduce(result, 0, fn row, acc -> acc + row["count"] end)
    else
      nil
    end
  end

  defp infer_count(_result), do: nil

  defp infer_records(result) when is_list(result) do
    if Enum.all?(result, &is_map/1) do
      result
    else
      []
    end
  end

  defp infer_records(result) when is_map(result), do: [result]
  defp infer_records(_result), do: []

  defp put_language(opts, language) when is_list(opts), do: Keyword.put(opts, :language, language)
  defp put_language(%{} = opts, language), do: Map.put(opts, :language, language)
end
