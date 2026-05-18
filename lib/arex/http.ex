defmodule Arex.Http do
  @moduledoc """
  Low-level ArcadeDB HTTP transport.

  Most application code should prefer higher-level modules such as
  `Arex.Query`, `Arex.Command`, `Arex.Record`, `Arex.Schema`, `Arex.Vertex`,
  and `Arex.Edge`. This module is the thin boundary to the underlying Req-based
  transport layer.

  `Arex.Http` resolves options, builds authenticated requests, normalizes error
  responses, and applies the library's read-versus-write retry policy. It is
  useful for extensions and diagnostics, but most application code should stay
  on the higher-level helpers.
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

    with {:ok, req_options} <- build_req_options(method, path, body, resolved, mode) do
      case Req.request(req_options) do
        {:ok, %Req.Response{} = response} -> normalize_response(response, request_meta)
        {:error, exception} -> {:error, Error.transport(exception, request_meta)}
      end
    end
  end

  defp build_req_options(method, path, body, resolved, mode) do
    with {:ok, retry_options} <- retry_options(resolved.retry, mode, path) do
      base_options = [
        method: method,
        url: String.trim_trailing(resolved.url, "/") <> path,
        auth: {:basic, "#{resolved.user}:#{resolved.pwd}"},
        headers:
          Map.merge(
            %{"accept" => "application/json", "content-type" => "application/json"},
            resolved.headers
          ),
        receive_timeout: resolved.receive_timeout || @default_receive_timeout,
        http_errors: :return,
        retry: false
      ]

      base_options =
        if is_nil(body), do: base_options, else: Keyword.put(base_options, :json, body)

      {:ok,
       resolved.req_options
       |> Keyword.merge(base_options)
       |> Keyword.merge(retry_options)}
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
end
