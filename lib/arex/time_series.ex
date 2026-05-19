defmodule Arex.TimeSeries do
  @moduledoc """
  Time-series helpers for ArcadeDB TimeSeries types and endpoints.

  `Arex.TimeSeries` covers three layers of the ArcadeDB time-series surface:

  - SQL-backed DDL and analytical queries
  - dedicated JSON and line-protocol HTTP endpoints
  - PromQL, Grafana, and Prometheus-compatible HTTP endpoints

  The helpers return the same `{:ok, value}` and `{:error, error_map}` shapes as
  the rest of Arex. When you need a TimeSeries capability that is not wrapped
  here yet, use `Arex.Query.sql/3`, `Arex.Command.sql/3`, or `Arex.Http.request/4`.

  Arex treats time-series data as boundary-aware when you use the structured
  helpers:

  - helper-managed type creation adds `tenant` and `scope` tags when needed
  - helper-managed writes stamp active boundaries into rows or line protocol
  - wrapped SQL and latest-point helpers apply those boundary tags on read

  Raw SQL, raw PromQL, and raw payload helpers remain available when callers
  need full control over the underlying ArcadeDB surface.
  """

  alias Arex.Command
  alias Arex.Error
  alias Arex.Http
  alias Arex.Options
  alias Arex.Query
  alias Arex.Sql

  @doc "Creates a TimeSeries type with the given timestamp, tags, and fields definition."
  def create_type(name, timestamp, tags, fields, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name),
         {:ok, timestamp_clause} <- build_timestamp_clause(timestamp, opts),
         {:ok, tags_clause} <-
           build_columns_clause("tags", add_boundary_columns(tags, opts), true),
         {:ok, fields_clause} <- build_columns_clause("fields", fields, false),
         {:ok, options_clause} <- build_create_options(opts) do
      Command.sql(
        Enum.join(
          Enum.reject(
            [
              create_type_prefix(opts),
              name,
              timestamp_clause,
              tags_clause,
              fields_clause,
              options_clause
            ],
            &(&1 in [nil, ""])
          ),
          " "
        ),
        %{},
        opts
      )
    end
  end

  @doc "Drops a TimeSeries type."
  def drop_type(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      prefix =
        if Keyword.get(opts, :if_exists, false),
          do: "drop timeseries type if exists",
          else: "drop timeseries type"

      Command.sql("#{prefix} #{name}", %{}, opts)
    end
  end

  @doc "Adds one or more downsampling policies to a TimeSeries type."
  def add_downsampling_policy(name, policies, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name),
         {:ok, policy_clause} <- build_downsampling_policies(policies) do
      Command.sql(
        "alter timeseries type #{name} add downsampling policy #{policy_clause}",
        %{},
        opts
      )
    end
  end

  @doc "Drops all downsampling policies from a TimeSeries type."
  def drop_downsampling_policy(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Command.sql("alter timeseries type #{name} drop downsampling policy", %{}, opts)
    end
  end

  @doc "Creates a continuous aggregate."
  def create_continuous_aggregate(name, query, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name),
         :ok <- require_nonempty_string(query, :query) do
      Command.sql("create continuous aggregate #{name} as #{query}", %{}, opts)
    end
  end

  @doc "Refreshes a continuous aggregate."
  def refresh_continuous_aggregate(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Command.sql("refresh continuous aggregate #{name}", %{}, opts)
    end
  end

  @doc "Drops a continuous aggregate."
  def drop_continuous_aggregate(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Command.sql("drop continuous aggregate #{name}", %{}, opts)
    end
  end

  @doc "Lists continuous aggregates from `schema:continuousAggregates`."
  def continuous_aggregates(opts \\ []) do
    Query.sql("select from schema:continuousAggregates order by name", %{}, opts)
  end

  @doc "Executes a SQL query against TimeSeries data."
  def query_sql(statement, params \\ %{}, opts \\ []) do
    with {:ok, params} <- normalize_params(params),
         {:ok, statement, params} <- add_query_boundary(statement, params, opts) do
      Query.sql(statement, params, opts)
    end
  end

  @doc "Evaluates a PromQL expression through SQL using `promql()`."
  def promql_sql(expression, timestamp_ms \\ nil, opts \\ []) do
    with :ok <- require_nonempty_string(expression, :expression) do
      case timestamp_ms do
        nil ->
          Query.run("return promql(:expression)", %{"expression" => expression}, opts)

        value when is_integer(value) ->
          Query.run(
            "return promql(:expression, :timestamp_ms)",
            %{"expression" => expression, "timestamp_ms" => value},
            opts
          )

        _other ->
          {:error,
           Error.bad_opts("timestamp_ms must be an integer", %{method: nil, path: nil}, %{
             key: :timestamp_ms
           })}
      end
    end
  end

  @doc "Inserts a single sample map into a TimeSeries type using SQL `content` syntax."
  def insert(type, attrs, opts \\ [])

  def insert(type, attrs, opts) when is_map(attrs) do
    with {:ok, type} <- Sql.validate_identifier(type),
         {:ok, attrs} <- Sql.normalize_map(attrs) do
      attrs = Sql.stamp_boundaries(attrs, boundary_values(opts))
      Command.sql("insert into #{type} content #{Sql.json_map(attrs)}", %{}, opts)
    end
  end

  def insert(_type, _attrs, _opts) do
    {:error, Error.bad_opts("attrs must be a map", %{method: nil, path: nil})}
  end

  @doc "Inserts multiple sample maps into a TimeSeries type in one SQLScript transaction."
  def insert_many(type, rows, opts \\ [])

  def insert_many(type, rows, opts) when is_list(rows) do
    with {:ok, type} <- Sql.validate_identifier(type),
         {:ok, resolved} <- Options.resolve(opts),
         {:ok, script} <- build_insert_script(type, rows, resolved),
         {:ok, %{records: records}} <- Command.sqlscript(script, %{}, resolved) do
      {:ok, parse_batch_rows(records)}
    end
  end

  def insert_many(_type, _rows, _opts) do
    {:error, Error.bad_opts("rows must be a list", %{method: nil, path: nil})}
  end

  @doc "Writes InfluxDB line protocol samples to `/api/v1/ts/:db/write`."
  def write_lines(lines, opts \\ []) do
    with {:ok, payload} <- normalize_lines(lines, opts),
         {:ok, precision_query} <- precision_query(opts),
         {:ok, resolved, db} <- resolve_db(opts, "/api/v1/ts/:db/write") do
      Http.request(
        :post,
        "/api/v1/ts/#{db}/write",
        payload,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(
          mode: :write,
          body_mode: :raw,
          content_type: "text/plain",
          accept: "application/json",
          query: precision_query,
          response: :decoded
        )
      )
    end
  end

  @doc "Executes a TimeSeries JSON query against `/api/v1/ts/:db/query`."
  def query_json(payload, opts \\ [])

  def query_json(payload, opts) when is_map(payload) do
    with {:ok, resolved, db} <- resolve_db(opts, "/api/v1/ts/:db/query") do
      Http.request(
        :post,
        "/api/v1/ts/#{db}/query",
        payload,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read)
      )
    end
  end

  def query_json(_payload, _opts) do
    {:error, Error.bad_opts("payload must be a map", %{method: nil, path: nil})}
  end

  @doc "Fetches the latest point for a TimeSeries type."
  def latest(type, opts \\ []) do
    with {:ok, type} <- Sql.validate_identifier(type),
         {:ok, resolved, db} <- resolve_db(opts, "/api/v1/ts/:db/latest") do
      Http.request(
        :get,
        "/api/v1/ts/#{db}/latest",
        nil,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read, query: latest_query(type, opts))
      )
    end
  end

  @doc "Executes a PromQL instant query."
  def promql(expression, opts \\ []) do
    with :ok <- require_nonempty_string(expression, :expression),
         {:ok, resolved, db} <- resolve_db(opts, "/ts/:db/prom/api/v1/query") do
      Http.request(
        :get,
        "/ts/#{db}/prom/api/v1/query",
        nil,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read, query: instant_query_params(expression, opts))
      )
    end
  end

  @doc "Executes a PromQL range query."
  def promql_range(expression, opts \\ []) do
    with :ok <- require_nonempty_string(expression, :expression),
         :ok <- validate_range_opts(opts),
         {:ok, resolved, db} <- resolve_db(opts, "/ts/:db/prom/api/v1/query_range") do
      Http.request(
        :get,
        "/ts/#{db}/prom/api/v1/query_range",
        nil,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read, query: range_query_params(expression, opts))
      )
    end
  end

  @doc "Lists available PromQL label names."
  def prom_labels(opts \\ []) do
    prom_get("/labels", %{}, opts)
  end

  @doc "Lists available values for a PromQL label."
  def prom_label_values(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      prom_get("/label/#{name}/values", %{}, opts)
    end
  end

  @doc "Finds series matching one or more PromQL selectors."
  def prom_series(matchers, opts \\ []) do
    values = List.wrap(matchers)

    if values == [] or Enum.any?(values, &(not is_binary(&1) or &1 == "")) do
      {:error,
       Error.bad_opts("matchers must be a non-empty list of strings", %{method: nil, path: nil})}
    else
      prom_get("/series", %{"match[]" => values}, opts)
    end
  end

  @doc "Sends a raw Prometheus remote-write payload."
  def prom_remote_write(payload, opts \\ [])

  def prom_remote_write(payload, opts) when is_binary(payload) do
    prom_binary_post("/write", payload, opts)
  end

  def prom_remote_write(_payload, _opts) do
    {:error, Error.bad_opts("payload must be a binary", %{method: nil, path: nil})}
  end

  @doc "Sends a raw Prometheus remote-read payload."
  def prom_remote_read(payload, opts \\ [])

  def prom_remote_read(payload, opts) when is_binary(payload) do
    prom_binary_post("/read", payload, opts)
  end

  def prom_remote_read(_payload, _opts) do
    {:error, Error.bad_opts("payload must be a binary", %{method: nil, path: nil})}
  end

  @doc "Checks the Grafana datasource health endpoint for ArcadeDB TimeSeries."
  def grafana_health(opts \\ []) do
    ts_api_get("/grafana/health", %{}, opts)
  end

  @doc "Fetches Grafana metadata for ArcadeDB TimeSeries types."
  def grafana_metadata(opts \\ []) do
    ts_api_get("/grafana/metadata", %{}, opts)
  end

  @doc "Executes a Grafana DataFrame-style query."
  def grafana_query(payload, opts \\ [])

  def grafana_query(payload, opts) when is_map(payload) do
    ts_api_post("/grafana/query", payload, opts)
  end

  def grafana_query(_payload, _opts) do
    {:error, Error.bad_opts("payload must be a map", %{method: nil, path: nil})}
  end

  defp build_timestamp_clause(timestamp, opts) do
    with {:ok, timestamp_name} <- normalize_timestamp_name(timestamp),
         {:ok, precision} <- timestamp_precision(Keyword.get(opts, :precision)) do
      {:ok,
       Enum.reject(
         [
           "timestamp",
           timestamp_name,
           precision && ["precision", precision]
         ],
         &is_nil/1
       )
       |> List.flatten()
       |> Enum.join(" ")}
    end
  end

  defp normalize_timestamp_name({name, _type}), do: Sql.validate_identifier(name)
  defp normalize_timestamp_name(name), do: Sql.validate_identifier(name)

  defp build_columns_clause(_label, [], true), do: {:ok, nil}

  defp build_columns_clause(label, columns, allow_empty?) when is_list(columns) do
    if columns == [] and not allow_empty? do
      {:error, Error.bad_opts("#{label} must be a non-empty list", %{method: nil, path: nil})}
    else
      columns
      |> Enum.reduce_while({:ok, []}, fn column, {:ok, acc} ->
        case normalize_column(column) do
          {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, []} -> {:ok, nil}
        {:ok, normalized} -> {:ok, "#{label} (#{Enum.join(normalized, ", ")})"}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp build_columns_clause(_label, _columns, _allow_empty?) do
    {:error, Error.bad_opts("columns must be a list", %{method: nil, path: nil})}
  end

  defp normalize_column({name, type}) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      {:ok, "#{name} #{normalize_keywordish(type)}"}
    end
  end

  defp normalize_column(%{name: name, type: type}), do: normalize_column({name, type})
  defp normalize_column(%{"name" => name, "type" => type}), do: normalize_column({name, type})

  defp normalize_column(_column) do
    {:error,
     Error.bad_opts(
       "columns must be tuples or maps with name and type",
       %{method: nil, path: nil}
     )}
  end

  defp build_create_options(opts) do
    allowed = [
      {:shards, "shards"},
      {:retention, "retention"},
      {:compaction_interval, "compaction_interval"},
      {:block_size, "block_size"}
    ]

    {:ok,
     allowed
     |> Enum.reduce([], fn {key, label}, acc ->
       case Keyword.get(opts, key) do
         nil -> acc
         value -> acc ++ [label, normalize_keywordish(value)]
       end
     end)
     |> Enum.join(" ")}
  end

  defp create_type_prefix(opts) do
    if Keyword.get(opts, :if_not_exists, false),
      do: "create timeseries type if not exists",
      else: "create timeseries type"
  end

  defp build_downsampling_policies(policies) when is_list(policies) and policies != [] do
    policies
    |> Enum.reduce_while({:ok, []}, fn policy, {:ok, acc} ->
      case normalize_policy(policy) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.join(normalized, " ")}
      {:error, error} -> {:error, error}
    end
  end

  defp build_downsampling_policies(_policies) do
    {:error, Error.bad_opts("policies must be a non-empty list", %{method: nil, path: nil})}
  end

  defp normalize_policy(policy) when is_list(policy) do
    normalize_policy(Enum.into(policy, %{}))
  end

  defp normalize_policy(%{after: after_value, granularity: granularity}) do
    {:ok,
     "after #{normalize_keywordish(after_value)} granularity #{normalize_keywordish(granularity)}"}
  end

  defp normalize_policy(%{"after" => after_value, "granularity" => granularity}) do
    {:ok,
     "after #{normalize_keywordish(after_value)} granularity #{normalize_keywordish(granularity)}"}
  end

  defp normalize_policy(_policy) do
    {:error,
     Error.bad_opts(
       "policies must contain after and granularity",
       %{method: nil, path: nil}
     )}
  end

  defp normalize_keywordish(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_keywordish(value) when is_binary(value), do: value
  defp normalize_keywordish(value), do: to_string(value)

  defp timestamp_precision(nil), do: {:ok, nil}

  defp timestamp_precision(value) do
    case value |> normalize_keywordish() |> String.upcase() do
      precision when precision in ["SECOND", "MILLISECOND", "MICROSECOND", "NANOSECOND"] ->
        {:ok, precision}

      _other ->
        {:error,
         Error.bad_opts(
           "precision must be SECOND, MILLISECOND, MICROSECOND, or NANOSECOND",
           %{method: nil, path: nil},
           %{key: :precision}
         )}
    end
  end

  defp build_insert_script(type, rows, resolved) do
    if rows == [] do
      {:error, Error.bad_opts("rows must be a non-empty list", %{method: nil, path: nil})}
    else
      rows
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, {[], []}}, fn {row, index}, {:ok, {statements, returns}} ->
        case Sql.normalize_map(row) do
          {:ok, attrs} ->
            return_var = "item#{index}"
            attrs = Sql.stamp_boundaries(attrs, resolved)

            {:cont,
             {:ok,
              {statements ++
                 ["let #{return_var} = insert into #{type} content #{Sql.json_map(attrs)}"],
               returns ++ [return_var]}}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, {statements, returns}} ->
          {:ok,
           [
             "begin",
             Enum.join(statements, "; "),
             "commit",
             "return [#{Enum.map_join(returns, ",", &"$#{&1}")}]"
           ]
           |> Enum.join("; ")
           |> Kernel.<>(";")}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp parse_batch_rows(rows) do
    Enum.map(rows, fn
      %{"value" => [record | _]} -> record
      %{"value" => record} when is_map(record) -> record
      %{"value" => value} -> value
      record -> record
    end)
  end

  defp normalize_lines(lines, opts) when is_binary(lines) do
    {:ok,
     lines |> String.split("\n", trim: false) |> stamp_line_boundaries(opts) |> Enum.join("\n")}
  end

  defp normalize_lines(lines, opts) when is_list(lines) do
    with {:ok, normalized_lines} <- normalize_line_list(lines) do
      {:ok, normalized_lines |> stamp_line_boundaries(opts) |> Enum.join("\n")}
    end
  end

  defp normalize_lines(_lines, _opts) do
    {:error,
     Error.bad_opts("lines must be a string or list of strings", %{method: nil, path: nil})}
  end

  defp precision_query(opts) do
    case Keyword.get(opts, :precision) do
      nil -> {:ok, []}
      value -> write_precision(value)
    end
  end

  defp write_precision(value) do
    case value |> normalize_keywordish() |> String.downcase() do
      value when value in ["ns", "nanosecond", "nanoseconds"] ->
        {:ok, [precision: "ns"]}

      value when value in ["us", "microsecond", "microseconds"] ->
        {:ok, [precision: "us"]}

      value when value in ["ms", "millisecond", "milliseconds"] ->
        {:ok, [precision: "ms"]}

      value when value in ["s", "second", "seconds"] ->
        {:ok, [precision: "s"]}

      _other ->
        {:error,
         Error.bad_opts(
           "precision must be ns, us, ms, or s",
           %{method: nil, path: nil},
           %{key: :precision}
         )}
    end
  end

  defp latest_query(type, opts) do
    tags =
      opts
      |> Keyword.get(:tags, %{})
      |> Enum.map(fn {key, value} -> {"tag", "#{key}:#{value}"} end)
      |> Kernel.++(boundary_query_tags(opts))

    [type: type] ++ tags
  end

  defp add_boundary_columns(columns, opts) do
    boundary_columns =
      opts
      |> boundary_tag_columns()
      |> Enum.reject(fn {name, _type} ->
        Enum.any?(List.wrap(columns), &(column_name(&1) == name))
      end)

    List.wrap(columns) ++ boundary_columns
  end

  defp boundary_tag_columns(opts) do
    boundary = boundary_values(opts)

    []
    |> maybe_add_boundary_column("tenant", boundary.tenant)
    |> maybe_add_boundary_column("scope", boundary.scope)
  end

  defp maybe_add_boundary_column(columns, _name, nil), do: columns
  defp maybe_add_boundary_column(columns, name, _value), do: columns ++ [{name, :string}]

  defp column_name({name, _type}) when is_atom(name), do: Atom.to_string(name)
  defp column_name({name, _type}) when is_binary(name), do: name
  defp column_name(%{name: name}), do: column_name({name, nil})
  defp column_name(%{"name" => name}), do: column_name({name, nil})
  defp column_name(_column), do: nil

  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(params) when is_list(params), do: {:ok, Enum.into(params, %{})}

  defp normalize_params(_params) do
    {:error, Error.bad_opts("params must be a map or keyword list", %{method: nil, path: nil})}
  end

  defp add_query_boundary(statement, params, opts) do
    boundary = boundary_values(opts)

    clauses =
      []
      |> maybe_add_boundary_clause("tenant", boundary.tenant, "__arex_ts_tenant")
      |> maybe_add_boundary_clause("scope", boundary.scope, "__arex_ts_scope")

    if clauses == [] do
      {:ok, statement, params}
    else
      trimmed_statement = statement |> String.trim() |> String.trim_trailing(";")

      {:ok,
       "select from (#{trimmed_statement}) where #{Enum.map_join(clauses, " and ", &elem(&1, 0))}",
       Enum.reduce(clauses, params, fn {_clause, {param_name, value}}, acc ->
         Map.put(acc, param_name, value)
       end)}
    end
  end

  defp maybe_add_boundary_clause(clauses, _field, nil, _param_name), do: clauses

  defp maybe_add_boundary_clause(clauses, field, value, param_name) do
    clauses ++ [{"#{field} = :#{param_name}", {param_name, value}}]
  end

  defp boundary_values(opts) do
    case Options.resolve(opts) do
      {:ok, resolved} -> %{tenant: resolved.tenant, scope: resolved.scope}
      {:error, _error} -> %{tenant: nil, scope: nil}
    end
  end

  defp boundary_query_tags(opts) do
    boundary = boundary_values(opts)

    []
    |> maybe_add_query_tag("tenant", boundary.tenant)
    |> maybe_add_query_tag("scope", boundary.scope)
  end

  defp maybe_add_query_tag(tags, _name, nil), do: tags
  defp maybe_add_query_tag(tags, name, value), do: tags ++ [{"tag", "#{name}:#{value}"}]

  defp normalize_line_list(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn
      line, {:ok, acc} when is_binary(line) ->
        {:cont, {:ok, acc ++ [line]}}

      _line, _acc ->
        {:halt,
         {:error,
          Error.bad_opts("lines must be a string or list of strings", %{method: nil, path: nil})}}
    end)
  end

  defp stamp_line_boundaries(lines, opts) do
    tags = boundary_line_tags(opts)

    if tags == [] do
      lines
    else
      Enum.map(lines, &stamp_line_boundary(&1, tags))
    end
  end

  defp boundary_line_tags(opts) do
    boundary = boundary_values(opts)

    []
    |> maybe_add_line_tag("tenant", boundary.tenant)
    |> maybe_add_line_tag("scope", boundary.scope)
  end

  defp maybe_add_line_tag(tags, _name, nil), do: tags
  defp maybe_add_line_tag(tags, name, value), do: tags ++ [{name, escape_line_tag_value(value)}]

  defp stamp_line_boundary("", _tags), do: ""

  defp stamp_line_boundary(line, tags) do
    case String.split(line, " ", parts: 2) do
      [measurement_and_tags, rest] ->
        measurement_and_tags <>
          "," <> Enum.map_join(tags, ",", fn {key, value} -> "#{key}=#{value}" end) <> " " <> rest

      [measurement_and_tags] ->
        measurement_and_tags <>
          "," <> Enum.map_join(tags, ",", fn {key, value} -> "#{key}=#{value}" end)
    end
  end

  defp escape_line_tag_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(" ", "\\ ")
    |> String.replace("=", "\\=")
  end

  defp instant_query_params(expression, opts) do
    [query: expression] ++ maybe_put_query([], :time, Keyword.get(opts, :time))
  end

  defp range_query_params(expression, opts) do
    [
      query: expression,
      start: Keyword.fetch!(opts, :start),
      end: Keyword.fetch!(opts, :end),
      step: Keyword.fetch!(opts, :step)
    ]
  end

  defp validate_range_opts(opts) do
    required = [:start, :end, :step]
    missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

    if missing == [] do
      :ok
    else
      {:error,
       Error.bad_opts(
         "start, end, and step are required",
         %{method: nil, path: nil},
         %{missing: missing}
       )}
    end
  end

  defp prom_get(path_suffix, params, opts) do
    with {:ok, resolved, db} <- resolve_db(opts, "/ts/:db/prom/api/v1") do
      Http.request(
        :get,
        "/ts/#{db}/prom/api/v1#{path_suffix}",
        nil,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read, query: params)
      )
    end
  end

  defp prom_binary_post(path_suffix, payload, opts) do
    with {:ok, resolved, db} <- resolve_db(opts, "/ts/:db/prom") do
      Http.request(
        :post,
        "/ts/#{db}/prom#{path_suffix}",
        payload,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(
          mode: :write,
          body_mode: :raw,
          content_type: "application/x-protobuf",
          accept: "application/x-protobuf",
          response: :raw
        )
      )
    end
  end

  defp ts_api_get(path_suffix, params, opts) do
    with {:ok, resolved, db} <- resolve_db(opts, "/api/v1/ts/:db") do
      Http.request(
        :get,
        "/api/v1/ts/#{db}#{path_suffix}",
        nil,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read, query: params)
      )
    end
  end

  defp ts_api_post(path_suffix, payload, opts) do
    with {:ok, resolved, db} <- resolve_db(opts, "/api/v1/ts/:db") do
      Http.request(
        :post,
        "/api/v1/ts/#{db}#{path_suffix}",
        payload,
        resolved
        |> Map.put(:db, db)
        |> Map.to_list()
        |> Keyword.merge(mode: :read)
      )
    end
  end

  defp resolve_db(opts, path) do
    with {:ok, resolved} <- Options.resolve(opts) do
      case resolved.db do
        nil -> {:error, Error.database_required(%{method: nil, path: path})}
        db -> {:ok, resolved, db}
      end
    end
  end

  defp require_nonempty_string(value, _key) when is_binary(value) and value != "", do: :ok

  defp require_nonempty_string(_value, key) do
    {:error,
     Error.bad_opts("#{key} must be a non-empty string", %{method: nil, path: nil}, %{key: key})}
  end

  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, key, value), do: params ++ [{key, value}]
end
