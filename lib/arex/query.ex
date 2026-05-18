defmodule Arex.Query do
  @moduledoc """
  Read-oriented query helpers.

  `Arex.Query` is the lowest-friction way to execute read statements without
  dropping all the way to `Arex.Http`. It keeps option resolution, normalized
  error handling, and paging behavior aligned with the rest of the library.

  Use `sql/3` for ordinary ArcadeDB SQL queries and `run/3` when you want the
  query language to come from call options or application config.
  """

  alias Arex.Error
  alias Arex.Http

  @doc """
  Executes a raw query using the resolved query language.

  `language` comes from call options, application config, or the default
  `"sql"`. This helper is useful when you want `Arex` to honor the resolved
  language instead of forcing SQL.
  """
  def run(statement, params \\ %{}, opts \\ []) do
    Http.query_raw(statement, params, opts)
  end

  @doc """
  Executes a SQL query.

  This helper always forces `language: "sql"` regardless of any configured
  default language.
  """
  def sql(statement, params \\ %{}, opts \\ []) do
    run(statement, params, put_language(opts, "sql"))
  end

  @doc """
  Returns the first row from a paged query or `nil` when the query is empty.

  Internally this delegates to `page/3` with `limit: 1`.
  """
  def first(statement, params \\ %{}, opts \\ []) do
    case page(statement, params, Keyword.merge([limit: 1, offset: 0], opts)) do
      {:ok, %{entries: [row | _]}} -> {:ok, row}
      {:ok, %{entries: []}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns exactly one row or `nil`.

  When the query returns more than one row, the function fails with a normalized
  `:multiple_results` error.
  """
  def one(statement, params \\ %{}, opts \\ []) do
    case page(statement, params, Keyword.merge([limit: 2, offset: 0], opts)) do
      {:ok, %{entries: []}} ->
        {:ok, nil}

      {:ok, %{entries: [row]}} ->
        {:ok, row}

      {:ok, %{entries: [_first, _second | _]}} ->
        {:error,
         Error.multiple_results(
           "expected one row but query returned more than one",
           %{method: :post, path: "/api/v1/query/:db"}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns one page of rows using ArcadeDB `skip` and `limit` semantics.

  The returned map contains `:entries`, `:limit`, `:offset`, `:count`, and
  `:has_more?`. Arex fetches one extra row internally so it can answer the
  `has_more?` question without requiring a separate count query.
  """
  def page(statement, params \\ %{}, opts \\ []) do
    {limit, opts} = Keyword.pop(opts, :limit, 100)
    {offset, opts} = Keyword.pop(opts, :offset, 0)

    cond do
      not (is_integer(limit) and limit > 0) ->
        {:error, Error.bad_opts("limit must be a positive integer", %{method: nil, path: nil})}

      not (is_integer(offset) and offset >= 0) ->
        {:error,
         Error.bad_opts("offset must be a non-negative integer", %{method: nil, path: nil})}

      true ->
        paged_statement = statement <> " skip :__arex_offset limit :__arex_limit"

        paged_params =
          params
          |> Map.new()
          |> Map.put("__arex_limit", limit + 1)
          |> Map.put("__arex_offset", offset)

        with {:ok, rows} <- run(paged_statement, paged_params, opts) do
          entries = Enum.take(rows, limit)

          {:ok,
           %{
             entries: entries,
             limit: limit,
             offset: offset,
             has_more?: length(rows) > limit,
             count: length(entries)
           }}
        end
    end
  end

  @doc """
  Streams query pages until there are no more rows.

  The stream yields `{:ok, page_map}` tuples and stops at the first error,
  which is yielded as `{:error, error_map}`.
  """
  def stream_pages(statement, params \\ %{}, opts \\ []) do
    {limit, opts} = Keyword.pop(opts, :limit, 100)
    {offset, opts} = Keyword.pop(opts, :offset, 0)

    if not (is_integer(limit) and limit > 0 and is_integer(offset) and offset >= 0) do
      {:error,
       Error.bad_opts(
         "limit must be positive and offset must be non-negative",
         %{method: nil, path: nil}
       )}
    else
      {:ok,
       Stream.resource(
         fn -> offset end,
         fn current_offset ->
           case page(statement, params, Keyword.merge(opts, limit: limit, offset: current_offset)) do
             {:ok, %{entries: []}} ->
               {:halt, current_offset}

             {:ok, page_map} ->
               next_offset = current_offset + limit

               if page_map.has_more? do
                 {[{:ok, page_map}], next_offset}
               else
                 {[{:ok, page_map}], :halt}
               end

             {:error, error} ->
               {[{:error, error}], :halt}
           end
         end,
         fn _state -> :ok end
       )}
    end
  end

  defp put_language(opts, language) when is_list(opts), do: Keyword.put(opts, :language, language)
  defp put_language(%{} = opts, language), do: Map.put(opts, :language, language)
end
