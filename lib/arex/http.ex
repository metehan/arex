defmodule Arex.Http do
  @moduledoc """
  Low-level ArcadeDB HTTP transport.

  Most application code should prefer higher-level modules such as
  `Arex.Query`, `Arex.Command`, `Arex.Record`, `Arex.Schema`, `Arex.Vertex`,
  and `Arex.Edge`. This module is the thin boundary to the underlying Req-based
  transport layer.

  `Arex.Http` resolves options, builds authenticated requests, normalizes error
  responses, and applies the library's read-versus-write retry policy. It is
  useful for extensions, diagnostics, and coverage of ArcadeDB endpoints that
  do not justify a dedicated public wrapper yet.

  Reach for `Arex.Http` when you need:

  - raw access to an ArcadeDB HTTP endpoint
  - custom request bodies, query params, or response decoding behavior
  - a temporary escape hatch while evaluating a new public helper

  Stay on the higher-level helpers when you want Arex to handle model-specific
  concerns such as boundary stamping, result normalization, or purpose-built
  input validation.
  """

  alias Arex.Error
  alias Arex.Options

  @default_receive_timeout 60_000

  @doc "Fetches ArcadeDB server metadata from `/api/v1/server`."
  def server_info(opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         :ok <- require_connection(resolved, %{method: :get, path: "/api/v1/server"}) do
      request(:get, "/api/v1/server", nil, resolved, :read)
    end
  end

  @doc "Performs an authenticated HTTP request against an arbitrary ArcadeDB path."
  def request(method, path, body \\ nil, opts \\ []) do
    mode = request_mode(method, Keyword.get(opts, :mode))
    request_meta = %{method: method, path: path}

    with :ok <- validate_path(path),
         {:ok, resolved} <- Options.resolve(opts),
         :ok <- require_connection(resolved, request_meta),
         {:ok, request_options} <- normalize_request_options(opts),
         {:ok, req_options} <-
           build_req_options(method, path, body, resolved, mode, request_options),
         {:ok, %Req.Response{} = response} <- perform_request(req_options) do
      normalize_response(response, request_meta)
    end
  end

  @doc "Lists databases visible to the configured server credentials."
  def list_databases(opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         :ok <- require_connection(resolved, %{method: :get, path: "/api/v1/databases"}),
         {:ok, body} <- request(:get, "/api/v1/databases", nil, resolved, :read) do
      {:ok, unwrap_result(body)}
    end
  end

  @doc "Checks whether a database exists on the configured server."
  def exists_database?(db_name, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         :ok <- require_connection(resolved, %{method: :get, path: "/api/v1/exists/#{db_name}"}),
         {:ok, body} <- request(:get, "/api/v1/exists/#{db_name}", nil, resolved, :read) do
      {:ok, unwrap_result(body)}
    end
  end

  @doc """
  Executes a server-scoped administrative command.

  This helper targets `/api/v1/server` and is used for operations such as
  database creation and deletion.
  """
  def server_command(command, opts \\ []) when is_binary(command) do
    with {:ok, resolved} <- Options.resolve(opts),
         :ok <- require_connection(resolved, %{method: :post, path: "/api/v1/server"}),
         {:ok, body} <-
           request(:post, "/api/v1/server", %{"command" => command}, resolved, :write) do
      {:ok, unwrap_result(body)}
    end
  end

  @doc """
  Executes a raw query request against `/api/v1/query/:db`.

  The target database must be resolved before the request is sent. Read retry
  settings are honored when present.
  """
  def query_raw(statement, params \\ %{}, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, db} <- require_db(resolved, %{method: :post, path: "/api/v1/query/:db"}),
         :ok <- require_connection(resolved, %{method: :post, path: "/api/v1/query/#{db}"}),
         {:ok, body} <-
           request(
             :post,
             "/api/v1/query/#{db}",
             %{
               "language" => resolved.language || "sql",
               "command" => statement,
               "params" => Map.new(params)
             },
             resolved,
             :read
           ) do
      {:ok, unwrap_result(body)}
    end
  end

  @doc """
  Executes a raw command request against `/api/v1/command/:db`.

  The target database must be resolved before the request is sent. Write
  helpers do not allow retry configuration.
  """
  def command_raw(statement, params \\ %{}, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, db} <- require_db(resolved, %{method: :post, path: "/api/v1/command/:db"}),
         :ok <- require_connection(resolved, %{method: :post, path: "/api/v1/command/#{db}"}),
         {:ok, body} <-
           request(
             :post,
             "/api/v1/command/#{db}",
             %{
               "language" => resolved.language || "sql",
               "command" => statement,
               "params" => Map.new(params)
             },
             resolved,
             :write
           ) do
      {:ok, unwrap_result(body)}
    end
  end

  @doc ~S|Unwraps the common `%{"result" => ...}` ArcadeDB response envelope when present.|
  def unwrap_result(%{"result" => result}), do: result
  def unwrap_result(body), do: body

  defp require_db(%{db: nil}, request), do: {:error, Error.database_required(request)}
  defp require_db(%{db: db}, _request), do: {:ok, db}

  defp require_connection(resolved, request) do
    missing = Enum.filter([:url, :user, :pwd], &(Map.get(resolved, &1) in [nil, ""]))

    case missing do
      [] -> :ok
      _ -> {:error, Error.bad_opts("missing connection settings", request, %{missing: missing})}
    end
  end

  defp request(method, path, body, resolved, mode) do
    request_meta = %{method: method, path: path}

    with {:ok, req_options} <- build_req_options(method, path, body, resolved, mode, %{}) do
      case perform_request(req_options) do
        {:ok, %Req.Response{} = response} -> normalize_response(response, request_meta)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp build_req_options(method, path, body, resolved, mode, request_options) do
    with {:ok, retry_options} <- retry_options(resolved.retry, mode, path) do
      query_params = Map.get(request_options, :query, [])
      response_mode = Map.get(request_options, :response_mode, :decoded)

      base_options = [
        method: method,
        url: String.trim_trailing(resolved.url, "/") <> path,
        auth: {:basic, "#{resolved.user}:#{resolved.pwd}"},
        headers:
          Map.merge(
            default_headers(request_options),
            Map.merge(resolved.headers, Map.get(request_options, :headers, %{}))
          ),
        receive_timeout: resolved.receive_timeout || @default_receive_timeout,
        http_errors: :return,
        retry: false,
        params: query_params,
        decode_body: response_mode == :decoded
      ]

      base_options = put_request_body(base_options, body, request_options)

      {:ok,
       resolved.req_options
       |> Keyword.merge(base_options)
       |> Keyword.merge(retry_options)}
    end
  end

  defp perform_request(req_options) do
    request_meta = %{
      method: Keyword.fetch!(req_options, :method),
      path: request_path(req_options)
    }

    case Req.request(req_options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, exception} -> {:error, Error.transport(exception, request_meta)}
    end
  end

  defp retry_options(false, _mode, _path), do: {:ok, [retry: false]}

  defp retry_options(retry, :write, path) when is_list(retry) do
    {:error,
     Error.bad_opts(
       "retry is not allowed for write helpers",
       %{method: :post, path: path}
     )}
  end

  defp retry_options(retry, :read, _path) when is_list(retry) do
    max = Keyword.fetch!(retry, :max)
    backoff_ms = Keyword.fetch!(retry, :backoff_ms)

    {:ok,
     [
       retry: :safe_transient,
       max_retries: max,
       retry_delay: fn attempt -> backoff_ms * trunc(:math.pow(2, attempt)) end
     ]}
  end

  defp retry_options(_retry, _mode, _path), do: {:ok, [retry: false]}

  defp normalize_response(%Req.Response{status: status, body: body}, request)
       when status >= 400 do
    {:error, Error.from_body(status, body, request)}
  end

  defp normalize_response(%Req.Response{status: status, body: %{"error" => _} = body}, request) do
    {:error, Error.from_body(status, body, request)}
  end

  defp normalize_response(%Req.Response{body: body}, _request), do: {:ok, body}

  defp validate_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      :ok
    else
      {:error, Error.bad_opts("path must start with /", %{method: nil, path: nil})}
    end
  end

  defp validate_path(_path) do
    {:error, Error.bad_opts("path must be a string", %{method: nil, path: nil})}
  end

  defp normalize_request_options(opts) do
    query = normalize_query_params(Keyword.get(opts, :query, []))
    headers = normalize_request_headers(Keyword.get(opts, :request_headers, %{}))
    response_mode = normalize_response_mode(Keyword.get(opts, :response, :decoded))

    body_mode =
      normalize_body_mode(
        Keyword.get(opts, :body_mode, infer_body_mode(Keyword.get(opts, :content_type)))
      )

    content_type = normalize_optional_header_value(Keyword.get(opts, :content_type))
    accept = normalize_optional_header_value(Keyword.get(opts, :accept))

    with {:ok, query} <- query,
         {:ok, headers} <- headers,
         {:ok, response_mode} <- response_mode,
         {:ok, body_mode} <- body_mode,
         {:ok, content_type} <- content_type,
         {:ok, accept} <- accept do
      {:ok,
       %{
         query: query,
         headers: headers,
         response_mode: response_mode,
         body_mode: body_mode,
         content_type: content_type,
         accept: accept
       }}
    end
  end

  defp normalize_query_params(query) when query in [nil, %{}, []], do: {:ok, []}
  defp normalize_query_params(query) when is_map(query), do: {:ok, Enum.into(query, [])}
  defp normalize_query_params(query) when is_list(query), do: {:ok, query}

  defp normalize_query_params(_query) do
    {:error, Error.bad_opts("query must be a map or keyword list", %{method: nil, path: nil})}
  end

  defp normalize_request_headers(headers) when headers in [nil, %{}, []], do: {:ok, %{}}

  defp normalize_request_headers(headers) when is_map(headers) do
    headers
    |> Enum.into([])
    |> normalize_request_headers()
  end

  defp normalize_request_headers(headers) when is_list(headers) do
    normalized =
      Enum.reduce(headers, %{}, fn {key, value}, acc ->
        Map.put(acc, header_name(key), to_string(value))
      end)

    {:ok, normalized}
  end

  defp normalize_request_headers(_headers) do
    {:error,
     Error.bad_opts("request_headers must be a map or keyword list", %{method: nil, path: nil})}
  end

  defp normalize_response_mode(:decoded), do: {:ok, :decoded}
  defp normalize_response_mode(:raw), do: {:ok, :raw}

  defp normalize_response_mode(_response_mode) do
    {:error, Error.bad_opts("response must be :decoded or :raw", %{method: nil, path: nil})}
  end

  defp normalize_body_mode(:json), do: {:ok, :json}
  defp normalize_body_mode(:raw), do: {:ok, :raw}

  defp normalize_body_mode(_body_mode) do
    {:error, Error.bad_opts("body_mode must be :json or :raw", %{method: nil, path: nil})}
  end

  defp normalize_optional_header_value(nil), do: {:ok, nil}
  defp normalize_optional_header_value(value) when is_binary(value), do: {:ok, value}

  defp normalize_optional_header_value(_value) do
    {:error, Error.bad_opts("content_type and accept must be strings", %{method: nil, path: nil})}
  end

  defp infer_body_mode("application/json"), do: :json
  defp infer_body_mode(_content_type), do: :raw

  defp default_headers(request_options) do
    %{}
    |> maybe_put_header("accept", Map.get(request_options, :accept) || "application/json")
    |> maybe_put_header(
      "content-type",
      Map.get(request_options, :content_type) || "application/json"
    )
  end

  defp put_request_body(base_options, nil, _request_options), do: base_options

  defp put_request_body(base_options, body, request_options) do
    case Map.get(request_options, :body_mode, :json) do
      :json -> Keyword.put(base_options, :json, body)
      :raw -> Keyword.put(base_options, :body, body)
    end
  end

  defp request_mode(method, nil) when method in [:get, :head], do: :read
  defp request_mode(_method, nil), do: :write
  defp request_mode(_method, :read), do: :read
  defp request_mode(_method, :write), do: :write
  defp request_mode(_method, _mode), do: :write

  defp header_name(key) do
    key
    |> to_string()
    |> String.replace("_", "-")
    |> String.downcase()
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, name, value), do: Map.put(headers, name, value)

  defp request_path(req_options) do
    req_options
    |> Keyword.fetch!(:url)
    |> URI.parse()
    |> Map.get(:path)
  end
end
