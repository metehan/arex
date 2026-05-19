defmodule Arex.Vector do
  @moduledoc """
  Vector search helpers for ArcadeDB dense, sparse, and hybrid retrieval.

  `Arex.Vector` wraps the ArcadeDB SQL surface for vector properties, dense
  `LSM_VECTOR` indexes, sparse `LSM_SPARSE_VECTOR` indexes, nearest-neighbor
  queries, and hybrid fusion.

  Use this module when the raw SQL is too repetitive or too easy to get wrong.
  It keeps the public API focused on the practical tasks most application code
  cares about:

  - declaring the right property types for embeddings
  - building dense and sparse vector indexes with validated options
  - issuing nearest-neighbor queries with structured parameters
  - composing hybrid fusion queries without hand-building metadata JSON

  The goal is not to hide the underlying ArcadeDB model, but to make the
  common vector workflows safer and easier to read.
  """

  alias Arex.Command
  alias Arex.Error
  alias Arex.Query
  alias Arex.Schema
  alias Arex.Sql

  @dense_metadata_keys [
    {:similarity, "similarity"},
    {:encoding, "encoding"},
    {:quantization, "quantization"},
    {:ef_search, "efSearch"},
    {:max_connections, "maxConnections"},
    {:beam_width, "beamWidth"},
    {:add_hierarchy, "addHierarchy"},
    {:store_vectors_in_graph, "storeVectorsInGraph"},
    {:build_graph_now, "buildGraphNow"}
  ]

  @fuse_option_keys [
    {:fusion, "fusion"},
    {:weights, "weights"},
    {:k, "k"},
    {:group_by, "groupBy"},
    {:group_size, "groupSize"}
  ]

  @query_option_keys [
    {:ef_search, "efSearch"},
    {:filter, "filter"},
    {:group_by, "groupBy"},
    {:group_size, "groupSize"}
  ]

  @doc "Builds the ArcadeDB index reference string `Type[property]`."
  def index_ref(type_name, property_name) do
    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, property_name} <- Sql.validate_identifier(property_name) do
      {:ok, "#{type_name}[#{property_name}]"}
    end
  end

  @doc "Creates an embedding property with the correct ArcadeDB type for the selected encoding."
  def create_embedding_property(type_name, property_name, opts \\ []) do
    with {:ok, property_type} <- embedding_property_type(opts) do
      Schema.create_property(type_name, property_name, property_type, opts)
    end
  end

  @doc "Creates the token and weight properties required for sparse vector indexes."
  def create_sparse_properties(type_name, tokens_property, weights_property, opts \\ []) do
    with {:ok, _} <-
           Schema.create_property(type_name, tokens_property, "ARRAY_OF_INTEGERS", opts),
         {:ok, _} <- Schema.create_property(type_name, weights_property, "ARRAY_OF_FLOATS", opts) do
      {:ok, :created}
    end
  end

  @doc "Creates a dense `LSM_VECTOR` index on an embedding property."
  def create_dense_index(type_name, property_name, dimensions, opts \\ []) do
    with {:ok, index_ref} <- index_ref(type_name, property_name),
         {:ok, dimensions} <- validate_dimensions(dimensions, :positive),
         {:ok, metadata} <- build_dense_metadata(dimensions, opts) do
      Command.sql(
        "create index on #{index_ref} LSM_VECTOR metadata #{metadata}",
        %{},
        opts
      )
    end
  end

  @doc "Creates a sparse `LSM_SPARSE_VECTOR` index on token and weight properties."
  def create_sparse_index(type_name, tokens_property, weights_property, opts \\ []) do
    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, tokens_property} <- Sql.validate_identifier(tokens_property),
         {:ok, weights_property} <- Sql.validate_identifier(weights_property),
         {:ok, dimensions} <-
           validate_dimensions(Keyword.get(opts, :dimensions, 0), :non_negative),
         {:ok, metadata} <- build_sparse_metadata(dimensions, opts) do
      Command.sql(
        "create index on #{type_name} (#{tokens_property}, #{weights_property}) LSM_SPARSE_VECTOR metadata #{metadata}",
        %{},
        opts
      )
    end
  end

  @doc "Runs a dense nearest-neighbor query and returns expanded result rows."
  def neighbors(index, query_vector, limit, opts \\ []) do
    with {:ok, index_ref} <- normalize_index(index),
         {:ok, query_vector} <- normalize_numeric_list(query_vector, :query_vector),
         {:ok, limit} <- validate_limit(limit),
         {:ok, query_options} <- build_query_options(opts) do
      Query.sql(
        "select expand(`vector.neighbors`(:index_ref, :query_vector, :limit#{query_options.placeholder_suffix}))",
        query_options.params
        |> Map.put("index_ref", index_ref)
        |> Map.put("query_vector", query_vector)
        |> Map.put("limit", limit),
        opts
      )
    end
  end

  @doc "Runs a sparse nearest-neighbor query and returns expanded result rows."
  def sparse_neighbors(index, query_indices, query_weights, limit, opts \\ []) do
    with {:ok, index_ref} <- normalize_sparse_index(index),
         {:ok, query_indices} <- normalize_integer_list(query_indices, :query_indices),
         {:ok, query_weights} <- normalize_numeric_list(query_weights, :query_weights),
         :ok <- validate_sparse_lengths(query_indices, query_weights),
         {:ok, limit} <- validate_limit(limit),
         {:ok, query_options} <- build_query_options(opts) do
      Query.sql(
        "select expand(`vector.sparseNeighbors`(:index_ref, :query_indices, :query_weights, :limit#{query_options.placeholder_suffix}))",
        query_options.params
        |> Map.put("index_ref", index_ref)
        |> Map.put("query_indices", query_indices)
        |> Map.put("query_weights", query_weights)
        |> Map.put("limit", limit),
        opts
      )
    end
  end

  @doc "Runs a hybrid vector fusion query from multiple ranked SQL sub-pipelines."
  def fuse(source_queries, opts \\ []) do
    with {:ok, source_queries} <- normalize_sources(source_queries),
         {:ok, fuse_options} <- build_fuse_options(opts),
         {:ok, outer_limit} <- validate_optional_limit(Keyword.get(opts, :limit)) do
      statement =
        [
          "select expand(`vector.fuse`(",
          Enum.join(source_queries, ", "),
          fuse_options,
          "))",
          outer_limit && " limit #{outer_limit}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join()

      Query.sql(statement, %{}, opts)
    end
  end

  defp embedding_property_type(opts) do
    encoding = normalize_keywordish(Keyword.get(opts, :encoding, :float32))
    external? = Keyword.get(opts, :external, false)

    property_type =
      case encoding do
        "FLOAT32" -> "ARRAY_OF_FLOATS"
        "INT8" -> "BINARY"
        _ -> nil
      end

    cond do
      property_type == nil ->
        {:error,
         Error.bad_opts(
           "encoding must be :float32 or :int8",
           %{method: nil, path: nil},
           %{key: :encoding}
         )}

      external? ->
        {:ok, "#{property_type} (EXTERNAL true)"}

      true ->
        {:ok, property_type}
    end
  end

  defp build_dense_metadata(dimensions, opts) do
    metadata =
      opts
      |> Enum.reduce(%{"dimensions" => dimensions}, fn {key, value}, acc ->
        case Enum.find(@dense_metadata_keys, fn {candidate, _label} -> candidate == key end) do
          nil -> acc
          {_candidate, label} -> Map.put(acc, label, normalize_metadata_value(value))
        end
      end)

    {:ok, Jason.encode!(metadata)}
  end

  defp build_sparse_metadata(dimensions, opts) do
    metadata =
      %{"dimensions" => dimensions}
      |> maybe_put_metadata("modifier", Keyword.get(opts, :modifier))

    {:ok, Jason.encode!(metadata)}
  end

  defp build_query_options(opts) do
    metadata =
      opts
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case Enum.find(@query_option_keys, fn {candidate, _label} -> candidate == key end) do
          nil -> acc
          {_candidate, label} -> Map.put(acc, label, normalize_metadata_value(value))
        end
      end)

    if map_size(metadata) == 0 do
      {:ok, %{params: %{}, placeholder_suffix: ""}}
    else
      {:ok,
       %{
         params: %{"query_options" => metadata},
         placeholder_suffix: ", :query_options"
       }}
    end
  end

  defp build_fuse_options(opts) do
    metadata =
      opts
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case Enum.find(@fuse_option_keys, fn {candidate, _label} -> candidate == key end) do
          nil -> acc
          {_candidate, label} -> Map.put(acc, label, normalize_metadata_value(value))
        end
      end)

    if map_size(metadata) == 0 do
      {:ok, ""}
    else
      {:ok, ", #{Jason.encode!(metadata)}"}
    end
  end

  defp normalize_index({type_name, property_name}), do: index_ref(type_name, property_name)

  defp normalize_index(index) when is_binary(index) do
    if Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]*\[[A-Za-z][A-Za-z0-9_]*\]$/, index) do
      {:ok, index}
    else
      {:error, Error.invalid_identifier(index, %{method: nil, path: nil})}
    end
  end

  defp normalize_index(index) do
    {:error, Error.invalid_identifier(inspect(index), %{method: nil, path: nil})}
  end

  defp normalize_sparse_index({type_name, tokens_property, weights_property}) do
    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, tokens_property} <- Sql.validate_identifier(tokens_property),
         {:ok, weights_property} <- Sql.validate_identifier(weights_property) do
      {:ok, "#{type_name}[#{tokens_property},#{weights_property}]"}
    end
  end

  defp normalize_sparse_index(index) when is_binary(index) do
    if Regex.match?(
         ~r/^[A-Za-z][A-Za-z0-9_]*\[[A-Za-z][A-Za-z0-9_]*,[A-Za-z][A-Za-z0-9_]*\]$/,
         index
       ) do
      {:ok, index}
    else
      {:error, Error.invalid_identifier(index, %{method: nil, path: nil})}
    end
  end

  defp normalize_sparse_index(index), do: normalize_index(index)

  defp normalize_numeric_list(values, key) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_integer(&1) or is_float(&1))) do
      {:ok, values}
    else
      {:error,
       Error.bad_opts(
         "#{key} must be a non-empty list of numbers",
         %{method: nil, path: nil},
         %{key: key}
       )}
    end
  end

  defp normalize_numeric_list(_values, key) do
    {:error,
     Error.bad_opts(
       "#{key} must be a non-empty list of numbers",
       %{method: nil, path: nil},
       %{key: key}
     )}
  end

  defp normalize_integer_list(values, key) when is_list(values) and values != [] do
    if Enum.all?(values, &is_integer/1) do
      {:ok, values}
    else
      {:error,
       Error.bad_opts(
         "#{key} must be a non-empty list of integers",
         %{method: nil, path: nil},
         %{key: key}
       )}
    end
  end

  defp normalize_integer_list(_values, key) do
    {:error,
     Error.bad_opts(
       "#{key} must be a non-empty list of integers",
       %{method: nil, path: nil},
       %{key: key}
     )}
  end

  defp normalize_sources(source_queries)
       when is_list(source_queries) and length(source_queries) >= 2 do
    if Enum.all?(source_queries, &(is_binary(&1) and &1 != "")) do
      {:ok, source_queries}
    else
      {:error,
       Error.bad_opts(
         "source_queries must be a list of non-empty SQL fragments",
         %{method: nil, path: nil}
       )}
    end
  end

  defp normalize_sources(_source_queries) do
    {:error,
     Error.bad_opts(
       "source_queries must contain at least two SQL fragments",
       %{method: nil, path: nil}
     )}
  end

  defp validate_dimensions(value, :positive) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_dimensions(value, :non_negative) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp validate_dimensions(_value, _mode) do
    {:error,
     Error.bad_opts(
       "dimensions must be a valid integer",
       %{method: nil, path: nil},
       %{key: :dimensions}
     )}
  end

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  defp validate_limit(_limit) do
    {:error,
     Error.bad_opts("limit must be a positive integer", %{method: nil, path: nil}, %{key: :limit})}
  end

  defp validate_optional_limit(nil), do: {:ok, nil}
  defp validate_optional_limit(limit), do: validate_limit(limit)

  defp validate_sparse_lengths(indices, weights) do
    if length(indices) == length(weights) do
      :ok
    else
      {:error,
       Error.bad_opts(
         "query_indices and query_weights must have the same length",
         %{method: nil, path: nil}
       )}
    end
  end

  defp normalize_metadata_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_metadata_value(value), do: value

  defp normalize_keywordish(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_keywordish(value), do: to_string(value)

  defp maybe_put_metadata(metadata, _key, nil), do: metadata

  defp maybe_put_metadata(metadata, key, value),
    do: Map.put(metadata, key, normalize_metadata_value(value))
end
