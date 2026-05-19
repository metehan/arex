defmodule Arex.Options do
  @moduledoc """
  Internal option normalization and precedence rules.

  Resolution order is:

  1. per-call options
  2. application config for `:arex`
  3. environment variables for `url`, `user`, `pwd`, and `db`

  `language` is not env-backed. It comes from call options or
  application config and otherwise defaults to `"sql"`.

  The resolved output is the internal options map used throughout Arex. This
  module validates boundary rules, normalizes string-like values, sanitizes
  transport options, and ensures callers cannot bypass retry policy through
  nested Req configuration.

  `Arex.Options` is public mainly for transparency and extension work. Typical
  application code should pass ordinary keyword lists to the public helpers and
  let those helpers resolve options internally.

  Use this module directly only when you are extending Arex or building wrapper
  layers that need to mirror the library's exact precedence and validation
  rules.
  """

  alias Arex.Error

  @env_keys %{
    url: "AREX_URL",
    user: "AREX_USER",
    pwd: "AREX_PWD",
    db: "AREX_DB"
  }

  @retry_req_keys [:retry, :max_retries, :retry_delay, :retry_log_level]

  @doc """
  Resolves Arex options into Arex's internal options map.

  Already-resolved maps are returned unchanged. Keyword-list input is validated,
  merged with config and environment fallback values, and normalized so
  connection-related values become strings internally.
  """
  def resolve(%{url: _} = resolved), do: {:ok, resolved}

  def resolve(call_opts) when is_list(call_opts) do
    config = Application.get_all_env(:arex)

    with {:ok, tenant} <- normalize_optional_string(Keyword.get(call_opts, :tenant), :tenant),
         {:ok, scope} <- normalize_optional_string(Keyword.get(call_opts, :scope), :scope),
         :ok <- validate_scope_and_tenant(tenant, scope),
         {:ok, type} <- normalize_optional_string(Keyword.get(call_opts, :type), :type),
         {:ok, transaction} <- normalize_transaction(Keyword.get(call_opts, :transaction, :auto)),
         {:ok, transaction_timeout} <-
           normalize_timeout(Keyword.get(call_opts, :transaction_timeout), :transaction_timeout),
         {:ok, receive_timeout} <-
           normalize_timeout(Keyword.get(call_opts, :receive_timeout), :receive_timeout),
         {:ok, retry} <- normalize_retry(Keyword.get(call_opts, :retry, false)),
         {:ok, headers} <- normalize_headers(Keyword.get(call_opts, :headers, %{})),
         {:ok, req_options} <- normalize_req_options(Keyword.get(call_opts, :req_options, [])) do
      {:ok,
       %{
         url: pick_connection_value(:url, call_opts, config),
         user: pick_connection_value(:user, call_opts, config),
         pwd: pick_connection_value(:pwd, call_opts, config),
         db: pick_connection_value(:db, call_opts, config),
         language: pick_language_value(call_opts, config) || "sql",
         type: type,
         tenant: tenant,
         scope: scope,
         transaction: transaction,
         transaction_timeout: transaction_timeout,
         receive_timeout: receive_timeout,
         retry: retry,
         headers: headers,
         req_options: req_options
       }
       |> normalize_connection_strings()}
    end
  end

  def resolve(_other) do
    {:error, Error.bad_opts("options must be a keyword list", %{method: nil, path: nil})}
  end

  @doc """
  Removes Req retry settings so callers cannot bypass Arex retry rules.

  This is applied before `req_options` are merged into the transport request.
  """
  def sanitize_req_options(req_options) when is_list(req_options) do
    req_options
    |> Keyword.drop(@retry_req_keys)
  end

  def sanitize_req_options(_), do: []

  defp pick_connection_value(key, call_opts, config) do
    Keyword.get(call_opts, key) || Keyword.get(config, key) ||
      System.get_env(Map.fetch!(@env_keys, key))
  end

  defp pick_language_value(call_opts, config) do
    Keyword.get(call_opts, :language) || Keyword.get(config, :language)
  end

  defp normalize_connection_strings(resolved) do
    Enum.reduce([:url, :user, :pwd, :db, :language], resolved, fn key, acc ->
      Map.update(acc, key, nil, fn
        nil -> nil
        value when is_atom(value) -> Atom.to_string(value)
        value -> to_string(value)
      end)
    end)
  end

  defp normalize_optional_string(nil, _key), do: {:ok, nil}
  defp normalize_optional_string(value, _key) when is_binary(value), do: {:ok, value}

  defp normalize_optional_string(value, _key) when is_atom(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_optional_string(_value, key) do
    {:error,
     Error.bad_opts("#{key} must be a string or atom", %{method: nil, path: nil}, %{key: key})}
  end

  defp validate_scope_and_tenant(_tenant, nil), do: :ok

  defp validate_scope_and_tenant(nil, _scope),
    do: {:error, Error.scope_without_tenant(%{method: nil, path: nil})}

  defp validate_scope_and_tenant(_tenant, _scope), do: :ok

  defp normalize_transaction(:auto), do: {:ok, :auto}
  defp normalize_transaction(:required), do: {:ok, :required}
  defp normalize_transaction(false), do: {:ok, false}

  defp normalize_transaction(_value) do
    {:error,
     Error.bad_opts(
       "transaction must be :auto, :required, or false",
       %{method: nil, path: nil}
     )}
  end

  defp normalize_timeout(nil, _key), do: {:ok, nil}
  defp normalize_timeout(value, _key) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_timeout(_value, key) do
    {:error,
     Error.bad_opts(
       "#{key} must be a positive integer",
       %{method: nil, path: nil},
       %{key: key}
     )}
  end

  defp normalize_retry(false), do: {:ok, false}
  defp normalize_retry(nil), do: {:ok, false}

  defp normalize_retry(retry) when is_list(retry) do
    max = Keyword.get(retry, :max, 3)
    backoff_ms = Keyword.get(retry, :backoff_ms, 200)

    if is_integer(max) and max >= 0 and is_integer(backoff_ms) and backoff_ms >= 0 do
      {:ok, [max: max, backoff_ms: backoff_ms]}
    else
      {:error,
       Error.bad_opts(
         "retry must be false or a keyword list with non-negative max and backoff_ms",
         %{method: nil, path: nil}
       )}
    end
  end

  defp normalize_retry(_retry) do
    {:error,
     Error.bad_opts(
       "retry must be false or a keyword list",
       %{method: nil, path: nil}
     )}
  end

  defp normalize_headers(headers) when headers in [%{}, []], do: {:ok, %{}}

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.into([])
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_list(headers) do
    normalized =
      headers
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        header_name =
          key
          |> to_string()
          |> String.replace("_", "-")
          |> String.downcase()

        if header_name == "authorization" do
          acc
        else
          Map.put(acc, header_name, to_string(value))
        end
      end)

    {:ok, normalized}
  end

  defp normalize_headers(_headers) do
    {:error, Error.bad_opts("headers must be a map or keyword list", %{method: nil, path: nil})}
  end

  defp normalize_req_options(nil), do: {:ok, []}

  defp normalize_req_options(req_options) when is_map(req_options) do
    req_options
    |> Enum.into([])
    |> normalize_req_options()
  end

  defp normalize_req_options(req_options) when is_list(req_options) do
    {:ok, sanitize_req_options(req_options)}
  end

  defp normalize_req_options(_req_options) do
    {:error,
     Error.bad_opts("req_options must be a keyword list or map", %{method: nil, path: nil})}
  end
end
