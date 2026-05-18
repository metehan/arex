defmodule Arex.Schema do
  @moduledoc """
  Schema, index, and bucket helpers.

  `Arex.Schema` keeps common ArcadeDB schema operations close to the underlying
  SQL commands while normalizing return values for missing resources. Use it to
  inspect types, create or drop schema elements, and provision buckets.
  """

  alias Arex.Command
  alias Arex.Query
  alias Arex.Sql

  @doc "Lists all types in the target database."
  def types(opts \\ []) do
    Query.sql("select from schema:types order by name", %{}, opts)
  end

  @doc "Returns one type row by name or `nil` when the type does not exist."
  def type(name, opts \\ []) do
    Query.first("select from schema:types where name = :name", %{"name" => to_string(name)}, opts)
  end

  @doc "Creates a document type."
  def create_document_type(name, opts \\ []), do: create_type("document", name, opts)
  @doc "Creates a vertex type."
  def create_vertex_type(name, opts \\ []), do: create_type("vertex", name, opts)
  @doc "Creates an edge type."
  def create_edge_type(name, opts \\ []), do: create_type("edge", name, opts)

  @doc "Drops a type when it exists, returning `{:ok, :missing}` when absent."
  def drop_type(name, opts \\ []) do
    with {:ok, identifier} <- Sql.validate_identifier(name),
         {:ok, existing} <- type(identifier, opts) do
      if is_nil(existing) do
        {:ok, :missing}
      else
        case Command.sql("drop type #{identifier} unsafe", %{}, opts) do
          {:ok, _result} -> {:ok, :dropped}
          {:error, error} -> {:error, error}
        end
      end
    end
  end

  @doc "Lists all properties for a type."
  def properties(type_name, opts \\ []) do
    Query.sql(
      "select expand(properties) from schema:types where name = :name",
      %{"name" => to_string(type_name)},
      opts
    )
  end

  @doc "Creates a property on a type using the given ArcadeDB property type."
  def create_property(type_name, property_name, property_type, opts \\ []) do
    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, property_name} <- Sql.validate_identifier(property_name) do
      Command.sql(
        "create property #{type_name}.#{property_name} #{property_type}",
        %{},
        opts
      )
    end
  end

  @doc "Drops a property and returns `{:ok, :missing}` when the property does not exist."
  def drop_property(type_name, property_name, opts \\ []) do
    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, property_name} <- Sql.validate_identifier(property_name) do
      case Command.sql("drop property #{type_name}.#{property_name}", %{}, opts) do
        {:ok, _result} -> {:ok, :dropped}
        {:error, %{kind: :arcadedb} = error} -> missing_or_error(error)
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc "Lists all indexes across all types in the target database."
  def indexes(opts \\ []) do
    Query.sql("select expand(indexes) from schema:types", %{}, opts)
  end

  @doc "Lists indexes for a single type."
  def indexes(type_name, opts) do
    Query.sql(
      "select expand(indexes) from schema:types where name = :name",
      %{"name" => to_string(type_name)},
      opts
    )
  end

  @doc """
  Creates an index on one or more fields.

  Pass `unique: true` for a unique index. Otherwise Arex emits ArcadeDB's
  explicit `notunique` type because that is the syntax required by the tested
  HTTP API.
  """
  def create_index(type_name, fields, opts \\ []) when is_list(fields) do
    {unique?, opts} = Keyword.pop(opts, :unique, false)

    with {:ok, type_name} <- Sql.validate_identifier(type_name),
         {:ok, validated_fields} <- validate_fields(fields) do
      index_type = if unique?, do: "unique", else: "notunique"

      Command.sql(
        "create index on #{type_name} (#{Enum.join(validated_fields, ", ")}) #{index_type}",
        %{},
        opts
      )
    end
  end

  @doc "Drops an index by name, returning `{:ok, :missing}` when absent."
  def drop_index(index_name, opts \\ []) do
    with {:ok, index_name} <- Sql.validate_index_name(index_name) do
      case Command.sql("drop index `#{index_name}`", %{}, opts) do
        {:ok, _result} -> {:ok, :dropped}
        {:error, %{kind: :arcadedb} = error} -> missing_or_error(error)
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc "Lists buckets in the target database."
  def buckets(opts \\ []) do
    Query.sql("select from schema:buckets order by name", %{}, opts)
  end

  @doc "Returns one bucket row by name or `nil` when the bucket does not exist."
  def bucket(name, opts \\ []) do
    Query.first(
      "select from schema:buckets where name = :name",
      %{"name" => to_string(name)},
      opts
    )
  end

  @doc "Creates a bucket."
  def create_bucket(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Command.sql("create bucket #{name}", %{}, opts)
    end
  end

  @doc "Drops a bucket and returns `{:ok, :missing}` when the bucket does not exist."
  def drop_bucket(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      case Command.sql("drop bucket #{name}", %{}, opts) do
        {:ok, _result} -> {:ok, :dropped}
        {:error, %{kind: :arcadedb} = error} -> missing_or_error(error)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp create_type(kind, name, opts) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Command.sql("create #{kind} type #{name}", %{}, opts)
    end
  end

  defp validate_fields(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      case Sql.validate_identifier(field) do
        {:ok, validated} -> {:cont, {:ok, acc ++ [validated]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp missing_or_error(%{message: message, details: details} = error) do
    haystacks = Enum.filter([message, details], &is_binary/1)

    if Enum.any?(haystacks, fn text ->
         String.contains?(text, "not found") or
           String.contains?(text, "does not exist") or
           String.contains?(text, "Cannot find")
       end) do
      {:ok, :missing}
    else
      {:error, error}
    end
  end
end
