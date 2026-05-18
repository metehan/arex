defmodule Arex do
  @moduledoc """
  Public entry points for connectivity checks and server metadata.

  `Arex` itself is intentionally small. Most application code will spend its
  time in `Arex.Record`, `Arex.Query`, `Arex.Command`, `Arex.Schema`,
  `Arex.Vertex`, and `Arex.Edge`, while this module provides a minimal
  server-level surface for health checks and diagnostics.

  Use this module when you need to confirm that the configured ArcadeDB server
  is reachable or when you want raw server metadata such as version details.
  The return contract matches the rest of the library: `{:ok, value}` on
  success and `{:error, error_map}` on failure.
  """

  alias Arex.Http

  @doc """
  Performs a lightweight connectivity check against the configured ArcadeDB server.

  This helper delegates to `server_info/1` and returns `{:ok, :pong}` when the
  server metadata request succeeds. On failure it returns the same normalized
  error tuple that `server_info/1` would return.
  """
  def ping(opts \\ []) do
    case server_info(opts) do
      {:ok, _info} -> {:ok, :pong}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Fetches raw server metadata from ArcadeDB.

  This is a thin wrapper over the low-level HTTP transport and is useful for
  diagnostics, startup checks, and admin tooling that needs server details such
  as version or server identity.
  """
  def server_info(opts \\ []) do
    Http.server_info(opts)
  end
end
