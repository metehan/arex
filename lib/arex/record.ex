defmodule Arex.Record do
  @moduledoc """
  Document-style CRUD helpers with tenant and scope awareness.

  `Arex.Record` is the main high-level API for working with ordinary ArcadeDB
  records. It stamps boundaries on writes, filters reads by boundaries when
  provided, and returns normalized errors for missing or ambiguous results.

  Input maps may use atom or string keys for ordinary fields. The module keeps
  common CRUD workflows, boundary enforcement, and RID-based operations out of
  handwritten SQL so application code can stay focused on domain logic.

  Reach for `Arex.Record` when you want:

  - inserts and updates decided from record shape
  - `where:`-based upserts
  - boundary-aware reads and deletes
  - batch persistence in one SQLScript transaction

  This is the module that most application code should start with before
  dropping to raw `Arex.Query` or `Arex.Command`.
  """

  alias Arex.Command
  alias Arex.Error
  alias Arex.Options
  alias Arex.Query
  alias Arex.Sql

  @doc """
  Inserts a new record or updates an existing one.

  Records without `@rid` are inserted. Records with `@rid` are updated by RID.
  """
  def persist(record, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, attrs} <- Sql.normalize_map(record) do
      case attrs["@rid"] do
        nil -> insert_record(attrs, resolved)
        _rid -> update_record(attrs, resolved)
      end
    end
  end

  @doc """
  Persists many records in a single SQLScript transaction.

  The batch succeeds or fails atomically. Records with `@rid` are updated and
  records without `@rid` are inserted.
  """
  def persist_multi(records, opts \\ []) do
    with true <-
           is_list(records) ||
             {:error, Error.bad_opts("records must be a list", %{method: nil, path: nil})},
         {:ok, resolved} <- Options.resolve(opts) do
      case records do
        [] ->
          {:ok, []}

        _records ->
          with {:ok, {statements, returns}} <- batch_statements(records, resolved),
               script when script != nil <- build_batch_script(statements, returns),
               {:ok, %{records: rows}} <- Command.sqlscript(script, %{}, resolved) do
            {:ok, parse_batch_rows(rows)}
          end
      end
    end
  end

  @doc "Inserts a copy of a record while ignoring any existing `@rid`."
  def persist_new(record, opts \\ []) do
    with {:ok, attrs} <- Sql.normalize_map(record) do
      attrs
      |> Map.delete("@rid")
      |> persist(opts)
    end
  end

  @doc "Fetches a record by RID and enforces the active tenant and scope boundary."
  def fetch(rid, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid) do
      case Query.sql("select from #{rid}", %{}, resolved) do
        {:ok, [record | _]} ->
          if Sql.matches_boundary?(record, resolved) do
            {:ok, record}
          else
            {:error,
             Error.not_found(
               "record not found",
               request_meta(resolved, :post, "/api/v1/query/:db")
             )}
          end

        {:ok, []} ->
          {:error,
           Error.not_found("record not found", request_meta(resolved, :post, "/api/v1/query/:db"))}

        {:error, %{kind: :arcadedb} = error} when is_binary(error.details) ->
          if String.contains?(error.details, "not found") or
               String.contains?(error.details, "Bucket with id") do
            {:error,
             Error.not_found(
               "record not found",
               request_meta(resolved, :post, "/api/v1/query/:db")
             )}
          else
            {:error, error}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Fetches many records by RID, returning `nil` for missing or out-of-boundary rows.

  This keeps the returned list aligned with the input RID order.
  """
  def fetch_multi(rids, opts \\ []) when is_list(rids) do
    with {:ok, resolved} <- Options.resolve(opts) do
      Enum.reduce_while(rids, {:ok, []}, fn rid, {:ok, acc} ->
        case fetch(rid, resolved) do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          {:error, %{kind: :not_found}} -> {:cont, {:ok, [nil | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  @doc """
  Finds records by filters and the required `type` option.

  Active `tenant` and `scope` values are appended automatically to the filter
  predicate when present.
  """
  def get(filters, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, type} <- require_type(resolved),
         {:ok, {where_clause, params}} <- Sql.build_filter_clause(filters, resolved) do
      limit = Keyword.get(opts, :limit, 1000)

      if not (is_integer(limit) and limit > 0) do
        {:error, Error.bad_opts("limit must be a positive integer", %{method: nil, path: nil})}
      else
        statement = "select from #{type} where #{where_clause} order by @rid limit :__limit"
        Query.sql(statement, Map.put(params, "__limit", limit), resolved)
      end
    end
  end

  @doc "Returns one matching record or `nil`, failing on ambiguous matches."
  def get_one(filters, opts \\ []) do
    case get(filters, Keyword.put(opts, :limit, 2)) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [record]} ->
        {:ok, record}

      {:ok, [_first, _second | _]} ->
        {:error,
         Error.multiple_results(
           "expected at most one record but found more than one",
           %{method: :post, path: "/api/v1/query/:db"}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Fetches one property from a record identified by RID."
  def get_property(rid, property, opts \\ []) do
    property = to_string(property)

    case fetch(rid, opts) do
      {:ok, record} -> {:ok, Map.get(record, property)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns whether at least one record matches the provided filters.

  This is a convenience wrapper over `get/2` with `limit: 1`.
  """
  def is_there?(filters, opts \\ []) do
    case get(filters, Keyword.put(opts, :limit, 1)) do
      {:ok, []} -> {:ok, false}
      {:ok, [_ | _]} -> {:ok, true}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Updates one mutable property and re-fetches the record."
  def update_property(rid, property, value, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid),
         {:ok, property} <- Sql.reject_protected_property(property),
         {:ok, current} <- fetch(rid, resolved),
         {:ok, target} <- conditional_target(current, rid, resolved),
         {:ok, result} <-
           Command.sql(
             "update #{target.type} set #{property} = :value where #{target.where}",
             Map.put(target.params, "value", value),
             resolved
           ),
         :ok <- ensure_mutated(result, resolved) do
      fetch(rid, resolved)
    end
  end

  @doc "Appends a value to a list property when it is not already present."
  def push(rid, property, value, opts \\ []) do
    with {:ok, record} <- fetch(rid, opts),
         {:ok, property} <- Sql.reject_protected_property(property) do
      case Map.get(record, property) do
        nil ->
          update_property(rid, property, [value], opts)

        list when is_list(list) ->
          if value in list,
            do: {:ok, record},
            else: update_property(rid, property, list ++ [value], opts)

        _other ->
          {:error,
           Error.bad_opts("property #{property} is not a list", %{method: nil, path: nil})}
      end
    end
  end

  @doc "Removes a value from a list property when present."
  def pop(rid, property, value, opts \\ []) do
    with {:ok, record} <- fetch(rid, opts),
         {:ok, property} <- Sql.reject_protected_property(property) do
      case Map.get(record, property) do
        nil ->
          {:ok, record}

        list when is_list(list) ->
          case List.delete(list, value) do
            ^list -> {:ok, record}
            new_list -> update_property(rid, property, new_list, opts)
          end

        _other ->
          {:error,
           Error.bad_opts("property #{property} is not a list", %{method: nil, path: nil})}
      end
    end
  end

  @doc "Sets a boolean property to `true`."
  def switch_on(rid, property, opts \\ []), do: update_property(rid, property, true, opts)
  @doc "Sets a boolean property to `false`."
  def switch_off(rid, property, opts \\ []), do: update_property(rid, property, false, opts)

  @doc "Merges attributes into an existing record and re-fetches the result."
  def merge(rid, attrs, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid),
         {:ok, normalized_attrs} <- Sql.normalize_map(attrs),
         {:ok, _attrs} <- Sql.reject_protected_attrs(normalized_attrs),
         {:ok, current} <- fetch(rid, resolved),
         {:ok, target} <- conditional_target(current, rid, resolved),
         {:ok, result} <-
           Command.sql(
             "update #{target.type} merge #{Sql.json_map(normalized_attrs)} where #{target.where}",
             target.params,
             resolved
           ),
         :ok <- ensure_mutated(result, resolved) do
      fetch(rid, resolved)
    end
  end

  @doc "Replaces a record's content while preserving its current boundary fields."
  def replace(rid, attrs, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid),
         {:ok, normalized_attrs} <- Sql.normalize_map(attrs),
         {:ok, _attrs} <- Sql.reject_protected_attrs(normalized_attrs),
         {:ok, current} <- fetch(rid, resolved) do
      content =
        normalized_attrs
        |> Sql.stamp_boundaries(%{tenant: current["tenant"], scope: current["scope"]})

      with {:ok, target} <- conditional_target(current, rid, resolved),
           {:ok, result} <-
             Command.sql(
               "update #{target.type} content #{Sql.json_map(content)} where #{target.where}",
               target.params,
               resolved
             ),
           :ok <- ensure_mutated(result, resolved) do
        fetch(rid, resolved)
      end
    end
  end

  @doc """
  Upserts one record by type and `where:` filter.

  The `where:` clause must be non-empty, and the operation fails when more than
  one row matches. Boundary fields from `opts` remain authoritative and are
  stamped onto the stored record.
  """
  def upsert(type, attrs, opts \\ []) do
    where = Keyword.get(opts, :where)

    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, type} <- Sql.validate_identifier(type),
         true <-
           not is_nil(where) or
             {:error, Error.bad_opts("where is required", %{method: nil, path: nil})},
         {:ok, normalized_where} <- Sql.normalize_map(where),
         {:ok, normalized_attrs} <- Sql.normalize_map(attrs),
         true <-
           map_size(normalized_where) > 0 or
             {:error, Error.bad_opts("where cannot be empty", %{method: nil, path: nil})},
         true <-
           map_size(normalized_attrs) > 0 or
             {:error, Error.bad_opts("attributes cannot be empty", %{method: nil, path: nil})},
         {:ok, {where_clause, where_params}} <-
           Sql.build_filter_clause(normalized_where, resolved),
         {:ok, existing} <-
           Query.sql("select from #{type} where #{where_clause} limit 2", where_params, resolved),
         :ok <- ensure_upsert_cardinality(existing),
         set_attrs <-
           normalized_where
           |> Map.merge(normalized_attrs)
           |> Sql.stamp_boundaries(resolved)
           |> Map.drop(["@rid", "@type", "@cat", "@in", "@out"]),
         {:ok, {set_clause, set_params}} <- Sql.build_assignment_clause(set_attrs),
         {:ok, _result} <-
           Command.sql(
             "update #{type} set #{set_clause} upsert where #{where_clause}",
             Map.merge(set_params, where_params),
             resolved
           ),
         {:ok, record} <- get_one(normalized_where, Keyword.put(opts, :type, type)) do
      {:ok, record}
    end
  end

  @doc "Deletes a record map that contains `@rid`."
  def vaporize(record, opts \\ []) do
    case rid(record) do
      nil -> {:error, Error.bad_opts("record must contain @rid", %{method: nil, path: nil})}
      rid -> vaporize_by_id(rid, opts)
    end
  end

  @doc "Deletes a record by RID."
  def vaporize_by_id(rid, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid),
         {:ok, record} <- fetch(rid, resolved),
         {:ok, target} <- conditional_target(record, rid, resolved),
         {:ok, result} <-
           Command.sql(
             "delete from #{target.type} where #{target.where}",
             target.params,
             resolved
           ),
         :ok <- ensure_mutated(result, resolved) do
      {:ok, :deleted}
    end
  end

  @doc "Extracts `@rid` from a record map."
  def rid(record) when is_map(record), do: record["@rid"] || record[:"@rid"]
  def rid(_record), do: nil

  @doc "Extracts `@type` from a record map."
  def type(record) when is_map(record), do: record["@type"] || record[:"@type"]
  def type(_record), do: nil

  @doc "Extracts `@cat` from a record map."
  def category(record) when is_map(record), do: record["@cat"] || record[:"@cat"]
  def category(_record), do: nil

  defp insert_record(attrs, resolved) do
    with {:ok, type} <- Sql.type_from_attrs(attrs, resolved),
         {:ok, type} <- Sql.validate_identifier(type),
         content = Sql.content_from_insert_attrs(attrs, resolved),
         {:ok, %{records: [record | _]}} <-
           Command.sql("insert into #{type} content #{Sql.json_map(content)}", %{}, resolved) do
      {:ok, record}
    end
  end

  defp update_record(attrs, resolved) do
    rid = attrs["@rid"]

    if resolved.type do
      {:error,
       Error.bad_opts("type is not allowed when updating by @rid", %{method: nil, path: nil})}
    else
      with {:ok, rid} <- Sql.validate_rid(rid),
           {:ok, current} <- fetch(rid, resolved),
           update_attrs <- Sql.drop_system_and_boundary_keys(attrs),
           {:ok, target} <- conditional_target(current, rid, resolved),
           {:ok, result} <-
             Command.sql(
               "update #{target.type} merge #{Sql.json_map(update_attrs)} where #{target.where}",
               target.params,
               resolved
             ),
           :ok <- ensure_mutated(result, resolved) do
        fetch(rid, resolved)
      end
    end
  end

  defp require_type(%{type: nil}), do: {:error, Error.type_required(%{method: nil, path: nil})}
  defp require_type(%{type: type}), do: Sql.validate_identifier(type)

  defp ensure_upsert_cardinality(rows) when is_list(rows) and length(rows) > 1 do
    {:error,
     Error.multiple_results(
       "upsert matched more than one record",
       %{method: :post, path: "/api/v1/query/:db"}
     )}
  end

  defp ensure_upsert_cardinality(_rows), do: :ok

  defp batch_statements(records, resolved) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], []}}, fn {record, index}, {:ok, {statements, returns}} ->
      case build_batch_item(record, index, resolved) do
        {:ok, {item_statements, return_var}} ->
          {:cont, {:ok, {statements ++ item_statements, returns ++ [return_var]}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp build_batch_item(record, index, resolved) do
    with {:ok, attrs} <- Sql.normalize_map(record) do
      case attrs["@rid"] do
        nil ->
          with {:ok, type} <- Sql.type_from_attrs(attrs, resolved),
               {:ok, type} <- Sql.validate_identifier(type) do
            return_var = "item#{index}"
            content = Sql.content_from_insert_attrs(attrs, resolved)

            {:ok,
             {[
                "let #{return_var} = insert into #{type} content #{Sql.json_map(content)}"
              ], return_var}}
          end

        rid ->
          with {:ok, rid} <- Sql.validate_rid(rid),
               {:ok, record} <- fetch(rid, resolved),
               {:ok, target} <- conditional_target_inline(record, rid, resolved) do
            return_var = "item#{index}"
            content = Sql.drop_system_and_boundary_keys(attrs)

            {:ok,
             {[
                "update #{target.type} merge #{Sql.json_map(content)} where #{target.where}",
                "let #{return_var} = select from #{target.type} where #{target.where}"
              ], return_var}}
          end
      end
    end
  end

  defp build_batch_script([], _returns), do: nil

  defp build_batch_script(statements, returns) do
    [
      "begin",
      Enum.join(statements, "; "),
      "commit",
      "return [#{Enum.map_join(returns, ",", &"$#{&1}")}]"
    ]
    |> Enum.join("; ")
    |> Kernel.<>(";")
  end

  defp parse_batch_rows(rows) do
    Enum.map(rows, fn
      %{"value" => [record | _]} -> record
      %{"value" => record} when is_map(record) -> record
      [record | _] -> record
      record -> record
    end)
  end

  defp conditional_target(current, rid, resolved) do
    with {:ok, type} <- current_record_type(current) do
      {where, params} = conditional_where(rid, resolved)
      {:ok, %{type: type, where: where, params: params}}
    end
  end

  defp conditional_target_inline(current, rid, resolved) do
    with {:ok, type} <- current_record_type(current) do
      {:ok, %{type: type, where: conditional_where_inline(rid, resolved)}}
    end
  end

  defp current_record_type(current) do
    case type(current) do
      nil -> {:error, Error.type_required(%{method: nil, path: nil})}
      type -> Sql.validate_identifier(type)
    end
  end

  defp conditional_where(rid, resolved) do
    {clauses, params} =
      {[], %{}}
      |> maybe_add_boundary_param("tenant", resolved.tenant, "__arex_tenant")
      |> maybe_add_boundary_param("scope", resolved.scope, "__arex_scope")

    {"@rid = #{rid}" <> prepend_boundary_clauses(clauses), params}
  end

  defp maybe_add_boundary_param({clauses, params}, _field, nil, _param_name),
    do: {clauses, params}

  defp maybe_add_boundary_param({clauses, params}, field, value, param_name) do
    {clauses ++ ["#{field} = :#{param_name}"], Map.put(params, param_name, value)}
  end

  defp conditional_where_inline(rid, resolved) do
    clauses =
      []
      |> maybe_add_boundary_literal("tenant", resolved.tenant)
      |> maybe_add_boundary_literal("scope", resolved.scope)

    "@rid = #{rid}" <> prepend_boundary_clauses(clauses)
  end

  defp maybe_add_boundary_literal(clauses, _field, nil), do: clauses

  defp maybe_add_boundary_literal(clauses, field, value) do
    clauses ++ ["#{field} = #{sql_string_literal(value)}"]
  end

  defp prepend_boundary_clauses([]), do: ""
  defp prepend_boundary_clauses(clauses), do: " and " <> Enum.join(clauses, " and ")

  defp sql_string_literal(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end

  defp ensure_mutated(%{count: 0}, resolved) do
    {:error,
     Error.not_found("record not found", request_meta(resolved, :post, "/api/v1/command/:db"))}
  end

  defp ensure_mutated(_result, _resolved), do: :ok

  defp request_meta(resolved, method, path) do
    %{method: method, path: String.replace(path, ":db", resolved.db || ":db")}
  end
end
