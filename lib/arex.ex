defmodule Arex do
  @moduledoc """
  Small top-level entry points for server reachability and metadata.

  `Arex` keeps the root module minimal. It does not expose a
  public client struct or a connection process. Instead, the library is
  organized into focused modules such as `Arex.Record`, `Arex.Query`,
  `Arex.Command`, `Arex.Schema`, `Arex.KV`, `Arex.TimeSeries`, `Arex.Vertex`,
  and `Arex.Edge`.

  Use this module when you need:

  - a lightweight startup or readiness check
  - server metadata such as version and server name
  - a simple top-level health probe without choosing a model-specific module

  Like the rest of Arex, these helpers return normalized `{:ok, value}` and
  `{:error, error_map}` tuples so application code can treat connectivity
  checks the same way it treats ordinary data access.
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
