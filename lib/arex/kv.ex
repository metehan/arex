defmodule Arex.KV do
  @moduledoc """
  Key/value helpers built on ArcadeDB's Redis-language command support.

  `Arex.KV` wraps the Redis-compatible HTTP command surface that ArcadeDB
  exposes through `/api/v1/command/:db` with `language: "redis"`.

  Use this module when you want transient Redis-style key/value operations or
  persistent hash-style commands without constructing raw Redis command strings
  by hand. Wrapped helpers apply active `tenant` and `scope` values as a key
  namespace. When you need a command that is not wrapped here, use `run/2`.

  The important distinction is between structured helpers and raw commands:

  - wrapped helpers such as `get/2`, `set/3`, `exists?/2`, and `hset/3` apply
    Arex boundary behavior when the target shape is known
  - `run/2` and `batch/2` remain raw Redis-language escape hatches

  That split keeps the public API predictable without pretending Arex can
  safely rewrite arbitrary Redis command strings.
  """

  alias Arex.Command
  alias Arex.Error
  alias Arex.Options
  alias Arex.Sql

  @index_target_regex ~r/^[A-Za-z][A-Za-z0-9_]*\[([A-Za-z][A-Za-z0-9_]*(?:,[A-Za-z][A-Za-z0-9_]*)*)\]$/
  @target_regex ~r/^[A-Za-z][A-Za-z0-9_]*(\[[A-Za-z][A-Za-z0-9_]*(?:,[A-Za-z][A-Za-z0-9_]*)*\])?$/

  @doc "Executes a raw Redis-language command and returns the normalized command result."
  def run(command, opts \\ []) when is_binary(command) do
    Command.run(command, %{}, put_language(opts))
  end

  @doc "Executes multiple Redis-language commands as a newline-delimited batch."
  def batch(commands, opts \\ [])

  def batch(commands, opts) when is_list(commands) do
    with {:ok, statements} <- normalize_commands(commands),
         {:ok, value} <- value(run(Enum.join(statements, "\n"), opts)) do
      {:ok, value}
    end
  end

  def batch(_commands, _opts) do
    {:error, Error.bad_opts("commands must be a list of strings", %{method: nil, path: nil})}
  end

  @doc "Sends `PING` and returns the Redis-compatible response payload."
  def ping(opts \\ []) do
    scalar("PING", opts)
  end

  @doc "Reads a transient key with `GET`."
  def get(key, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["GET", encode_token(key)], opts)
    end
  end

  @doc "Writes a transient key with `SET`."
  def set(key, value, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["SET", encode_token(key), encode_token(value)], opts)
    end
  end

  @doc "Deletes one or more transient keys with `DEL`."
  def delete(keys, opts \\ []) do
    with {:ok, encoded_keys} <- normalize_nonempty_tokens(keys, "keys", opts, &scoped_key/2) do
      scalar(["DEL" | encoded_keys], opts)
    end
  end

  @doc "Returns whether a transient key exists."
  def exists?(key, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts),
         {:ok, count} <- scalar(["EXISTS", encode_token(key)], opts) do
      {:ok, count not in [0, "0", nil, false]}
    end
  end

  @doc "Increments a transient numeric key by 1 with `INCR`."
  def incr(key, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["INCR", encode_token(key)], opts)
    end
  end

  @doc "Increments a transient numeric key by the provided amount with `INCRBY`."
  def incrby(key, amount, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["INCRBY", encode_token(key), encode_token(amount)], opts)
    end
  end

  @doc "Increments a transient numeric key by a floating-point amount with `INCRBYFLOAT`."
  def incrbyfloat(key, amount, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["INCRBYFLOAT", encode_token(key), encode_token(amount)], opts)
    end
  end

  @doc "Decrements a transient numeric key by 1 with `DECR`."
  def decr(key, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["DECR", encode_token(key)], opts)
    end
  end

  @doc "Decrements a transient numeric key by the provided amount with `DECRBY`."
  def decrby(key, amount, opts \\ []) do
    with {:ok, key} <- scoped_key(key, opts) do
      scalar(["DECRBY", encode_token(key), encode_token(amount)], opts)
    end
  end

  @doc "Retrieves a persistent record or indexed value with `HGET`."
  def hget(target, key, opts \\ []) do
    with {:ok, target} <- normalize_target(target),
         {:ok, key} <- scoped_lookup_key(target, key, opts) do
      scalar(["HGET", target, encode_token(key)], opts)
    end
  end

  @doc "Retrieves multiple persistent records or indexed values with `HMGET`."
  def hmget(target, keys, opts \\ []) do
    with {:ok, target} <- normalize_target(target),
         {:ok, encoded_keys} <-
           normalize_nonempty_tokens(keys, "keys", {target, opts}, &scoped_lookup_key/2),
         {:ok, value} <- value(run(Enum.join(["HMGET", target | encoded_keys], " "), opts)) do
      {:ok, List.wrap(value)}
    end
  end

  @doc "Creates or updates one persistent record payload with `HSET`."
  def hset(target, payload, opts \\ []) do
    with {:ok, target} <- normalize_target(target),
         {:ok, payload} <- scope_hash_payload(target, payload, opts) do
      scalar(["HSET", target, encode_token(payload)], opts)
    end
  end

  @doc "Deletes one or more persistent records or indexed entries with `HDEL`."
  def hdel(target, keys, opts \\ []) do
    with {:ok, target} <- normalize_target(target),
         {:ok, encoded_keys} <-
           normalize_nonempty_tokens(keys, "keys", {target, opts}, &scoped_lookup_key/2) do
      scalar(["HDEL", target | encoded_keys], opts)
    end
  end

  @doc "Unwraps the first `value` field from a normalized Redis-language command result."
  def value({:ok, %{records: [%{"value" => value} | _]}}), do: {:ok, value}
  def value({:ok, %{records: []}}), do: {:ok, nil}
  def value({:ok, %{records: records}}), do: {:ok, records}
  def value({:error, error}), do: {:error, error}

  defp scalar(parts, opts) when is_list(parts) do
    parts
    |> Enum.join(" ")
    |> run(opts)
    |> value()
  end

  defp scalar(command, opts) when is_binary(command) do
    command
    |> run(opts)
    |> value()
  end

  defp put_language(opts) when is_list(opts), do: Keyword.put(opts, :language, "redis")
  defp put_language(%{} = opts), do: Map.put(opts, :language, "redis")

  defp scoped_key(key, opts) do
    with {:ok, boundary} <- boundary(opts) do
      {:ok, namespace_key(stringify_key(key), boundary)}
    end
  end

  defp scoped_lookup_key({target, opts}, key), do: scoped_lookup_key(target, key, opts)

  defp scoped_lookup_key(target, key, opts) do
    with {:ok, boundary} <- boundary(opts),
         :ok <- reject_composite_boundary(target, boundary) do
      case index_lookup_field(target) do
        nil -> {:ok, stringify_key(key)}
        _field -> {:ok, namespace_key(stringify_key(key), boundary)}
      end
    end
  end

  defp scope_hash_payload(target, payload, opts) when is_map(payload) do
    with {:ok, attrs} <- Sql.normalize_map(payload),
         {:ok, boundary} <- boundary(opts),
         :ok <- reject_composite_boundary(target, boundary) do
      attrs = Sql.stamp_boundaries(attrs, boundary)

      {:ok,
       case index_lookup_field(target) do
         nil ->
           attrs

         field ->
           Map.update(attrs, field, nil, fn value ->
             namespace_key(stringify_key(value), boundary)
           end)
       end}
    end
  end

  defp scope_hash_payload(_target, payload, _opts), do: {:ok, payload}

  defp boundary(opts) do
    case Options.resolve(opts) do
      {:ok, resolved} -> {:ok, %{tenant: resolved.tenant, scope: resolved.scope}}
      {:error, error} -> {:error, error}
    end
  end

  defp namespace_key(key, %{tenant: nil, scope: nil}), do: key
  defp namespace_key(key, %{tenant: tenant, scope: nil}), do: "tenant:#{tenant}:#{key}"

  defp namespace_key(key, %{tenant: tenant, scope: scope}) do
    "tenant:#{tenant}:scope:#{scope}:#{key}"
  end

  defp normalize_commands(commands) do
    commands
    |> Enum.reduce_while({:ok, []}, fn
      command, {:ok, acc} when is_binary(command) ->
        {:cont, {:ok, acc ++ [command]}}

      _command, _acc ->
        {:halt,
         {:error, Error.bad_opts("commands must be a list of strings", %{method: nil, path: nil})}}
    end)
  end

  defp normalize_nonempty_tokens(values, _label, context, mapper)
       when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value, context) do
        {:ok, scoped_value} -> {:cont, {:ok, acc ++ [encode_token(scoped_value)]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_nonempty_tokens(_values, label, _context, _mapper) do
    {:error,
     Error.bad_opts("#{label} must be a non-empty list", %{method: nil, path: nil}, %{key: label})}
  end

  defp normalize_target(target) do
    target
    |> to_string()
    |> case do
      "" -> {:error, Error.bad_opts("target cannot be empty", %{method: nil, path: nil})}
      value -> validate_target(value)
    end
  end

  defp validate_target(target) do
    if Regex.match?(@target_regex, target) do
      {:ok, target}
    else
      {:error, Error.invalid_identifier(target, %{method: nil, path: nil})}
    end
  end

  defp index_lookup_field(target) do
    case index_lookup_fields(target) do
      [field] -> field
      _fields -> nil
    end
  end

  defp index_lookup_fields(target) do
    case Regex.run(@index_target_regex, target, capture: :all_but_first) do
      [fields] -> String.split(fields, ",")
      _other -> []
    end
  end

  defp reject_composite_boundary(_target, %{tenant: nil, scope: nil}), do: :ok

  defp reject_composite_boundary(target, _boundary) do
    if length(index_lookup_fields(target)) > 1 do
      {:error,
       Error.bad_opts(
         "boundary-aware composite KV targets are not supported by wrapped helpers",
         %{method: :post, path: "/api/v1/command/:db"},
         %{target: target}
       )}
    else
      :ok
    end
  end

  defp stringify_key(value) when is_binary(value), do: value
  defp stringify_key(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_key(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify_key(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp stringify_key(nil), do: "null"
  defp stringify_key(value), do: Jason.encode!(value)

  defp encode_token(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9_:\-\.\#\[\],]+$/, value) do
      value
    else
      Jason.encode!(value)
    end
  end

  defp encode_token(value) when is_atom(value), do: encode_token(Atom.to_string(value))
  defp encode_token(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp encode_token(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp encode_token(nil), do: "null"
  defp encode_token(value), do: Jason.encode!(value)
end
