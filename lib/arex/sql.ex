defmodule Arex.Sql do
  @moduledoc """
  Lower-level SQL validation and query-building helpers.

  Most application code should prefer `Arex.Record`, `Arex.Query`,
  `Arex.Schema`, and the graph helpers. `Arex.Sql` is useful when extending
  Arex or building custom wrappers on top of the same validation and boundary
  rules.
  """

  alias Arex.Error

  @identifier_regex ~r/^[A-Za-z][A-Za-z0-9_]*$/
  @index_name_regex ~r/^[A-Za-z][A-Za-z0-9_\[\], ]*$/
  @rid_regex ~r/^#\d+:\d+$/
  @protected_property_keys MapSet.new(["@rid", "@cat", "@in", "@out", "tenant", "scope"])

  @doc "Validates a type, property, or other generated SQL identifier."
  def validate_identifier(identifier) when is_atom(identifier),
    do: validate_identifier(Atom.to_string(identifier))

  def validate_identifier(identifier) when is_binary(identifier) do
    if Regex.match?(@identifier_regex, identifier) do
      {:ok, identifier}
    else
      {:error, Error.invalid_identifier(identifier, %{method: nil, path: nil})}
    end
  end

  def validate_identifier(identifier) do
    {:error, Error.invalid_identifier(inspect(identifier), %{method: nil, path: nil})}
  end

  @doc "Validates an ArcadeDB index name, including bracketed names such as `Customer[field]`."
  def validate_index_name(index_name) when is_atom(index_name),
    do: validate_index_name(Atom.to_string(index_name))

  def validate_index_name(index_name) when is_binary(index_name) do
    if Regex.match?(@index_name_regex, index_name) do
      {:ok, index_name}
    else
      {:error, Error.invalid_identifier(index_name, %{method: nil, path: nil})}
    end
  end

  def validate_index_name(index_name) do
    {:error, Error.invalid_identifier(inspect(index_name), %{method: nil, path: nil})}
  end

  @doc "Validates an ArcadeDB RID such as `#12:0`."
  def validate_rid(rid) when is_binary(rid) do
    if Regex.match?(@rid_regex, rid) do
      {:ok, rid}
    else
      {:error, Error.bad_opts("invalid RID: #{rid}", %{method: nil, path: nil}, %{rid: rid})}
    end
  end

  def validate_rid(rid) do
    {:error,
     Error.bad_opts("invalid RID: #{inspect(rid)}", %{method: nil, path: nil}, %{rid: rid})}
  end

  @doc "Normalizes a map so all keys are strings."
  def normalize_map(map) when is_map(map) do
    {:ok,
     Map.new(map, fn {key, value} ->
       {normalize_key(key), value}
     end)}
  end

  def normalize_map(_other) do
    {:error, Error.bad_opts("expected a map", %{method: nil, path: nil})}
  end

  @doc "Stamps active `tenant` and `scope` values onto an attribute map."
  def stamp_boundaries(attrs, %{tenant: tenant, scope: scope}) do
    attrs
    |> maybe_put_boundary("tenant", tenant)
    |> maybe_put_boundary("scope", scope)
  end

  @doc "Resolves the effective type from record attrs and the resolved `type` option."
  def type_from_attrs(attrs, %{type: opt_type}) do
    attr_type = attrs["@type"]

    cond do
      is_binary(attr_type) and is_binary(opt_type) and attr_type != opt_type ->
        {:error,
         Error.bad_opts(
           "type and @type must match when both are present",
           %{method: nil, path: nil},
           %{type: opt_type, attr_type: attr_type}
         )}

      is_binary(attr_type) ->
        {:ok, attr_type}

      is_binary(opt_type) ->
        {:ok, opt_type}

      true ->
        {:error, Error.type_required(%{method: nil, path: nil})}
    end
  end

  @doc "Drops system fields and stamps boundaries for insert content payloads."
  def content_from_insert_attrs(attrs, opts) do
    attrs
    |> Map.drop(["@rid", "@type", "@cat", "@in", "@out"])
    |> stamp_boundaries(opts)
  end

  @doc "Drops system-managed and boundary keys before merge-style updates."
  def drop_system_and_boundary_keys(attrs) do
    Map.drop(attrs, ["@rid", "@type", "@cat", "@in", "@out", "tenant", "scope"])
  end

  @doc "Rejects protected property names that helper APIs must not mutate directly."
  def reject_protected_property(property) do
    property = normalize_key(property)

    if MapSet.member?(@protected_property_keys, property) do
      {:error,
       Error.bad_opts(
         "property #{property} cannot be mutated through this helper",
         %{method: nil, path: nil},
         %{property: property}
       )}
    else
      validate_identifier(property)
    end
  end

  @doc "Rejects attribute maps that attempt to mutate protected or system-managed keys."
  def reject_protected_attrs(attrs) do
    attrs
    |> Map.keys()
    |> Enum.find(fn key -> MapSet.member?(@protected_property_keys, key) or key in ["@type"] end)
    |> case do
      nil ->
        {:ok, attrs}

      key ->
        {:error,
         Error.bad_opts(
           "attribute #{key} cannot be mutated through this helper",
           %{method: nil, path: nil},
           %{attribute: key}
         )}
    end
  end

  @doc "JSON-encodes a map for inline SQL `content` and `merge` clauses."
  def json_map(map), do: Jason.encode!(map)

  @doc "Builds a parameterized `where` clause from filters and the active boundary."
  def build_filter_clause(filters, opts) do
    with {:ok, normalized_filters} <- normalize_map(filters),
         :ok <- reject_special_filter_keys(normalized_filters) do
      all_filters =
        normalized_filters
        |> maybe_put_filter("tenant", opts.tenant)
        |> maybe_put_filter("scope", opts.scope)

      if map_size(all_filters) == 0 do
        {:error, Error.bad_opts("filters cannot be empty", %{method: nil, path: nil})}
      else
        Enum.reduce_while(all_filters, {[], %{}, 0}, fn {key, value}, {clauses, params, index} ->
          case validate_identifier(key) do
            {:ok, identifier} ->
              param_name = "f#{index}"

              {:cont,
               {["#{identifier} = :#{param_name}" | clauses], Map.put(params, param_name, value),
                index + 1}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end)
        |> case do
          {:error, error} ->
            {:error, error}

          {clauses, params, _index} ->
            {:ok, {Enum.reverse(clauses) |> Enum.join(" and "), params}}
        end
      end
    end
  end

  @doc "Builds a parameterized `set` clause from an attribute map."
  def build_assignment_clause(attrs, prefix \\ "s") do
    with {:ok, normalized_attrs} <- normalize_map(attrs) do
      if map_size(normalized_attrs) == 0 do
        {:error, Error.bad_opts("attributes cannot be empty", %{method: nil, path: nil})}
      else
        Enum.reduce_while(normalized_attrs, {[], %{}, 0}, fn {key, value},
                                                             {clauses, params, index} ->
          case validate_identifier(key) do
            {:ok, identifier} ->
              param_name = "#{prefix}#{index}"

              {:cont,
               {["#{identifier} = :#{param_name}" | clauses], Map.put(params, param_name, value),
                index + 1}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end)
        |> case do
          {:error, error} -> {:error, error}
          {clauses, params, _index} -> {:ok, {Enum.reverse(clauses) |> Enum.join(", "), params}}
        end
      end
    end
  end

  @doc "Returns whether a record matches the active `tenant` and `scope` boundary."
  def matches_boundary?(record, %{tenant: nil, scope: nil}), do: is_map(record)

  def matches_boundary?(record, %{tenant: tenant, scope: scope}) when is_map(record) do
    tenant_match = is_nil(tenant) or record["tenant"] == tenant
    scope_match = is_nil(scope) or record["scope"] == scope
    tenant_match and scope_match
  end

  def matches_boundary?(_record, _opts), do: false

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp maybe_put_boundary(map, _key, nil), do: map
  defp maybe_put_boundary(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_filter(map, _key, nil), do: map
  defp maybe_put_filter(map, key, value), do: Map.put(map, key, value)

  defp reject_special_filter_keys(filters) do
    forbidden = ["@rid", "@type", "@cat", "@in", "@out"]

    case Enum.find(Map.keys(filters), &(&1 in forbidden)) do
      nil -> :ok
      key -> {:error, Error.invalid_identifier(key, %{method: nil, path: nil})}
    end
  end
end
