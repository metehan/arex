defmodule Arex.Error do
  @moduledoc """
  Normalized error constructors used across Arex.

  Public helpers return `{:error, error_map}` tuples where `error_map.kind` is
  suitable for pattern matching and the remaining fields preserve debugging
  context from the originating request.

  The goal of this module is stability at the API boundary. Callers should be
  able to branch on `error.kind` without parsing raw response payloads, while
  still having access to the request metadata and any ArcadeDB-specific detail
  that was available.

  In practice this means:

  - transport errors and ArcadeDB errors share one shape
  - `kind` is the main field for pattern matching in application code
  - request metadata stays attached for observability and debugging
  - helper-level validation failures look the same as remote failures

  Most application code will not call these constructors directly, but the
  module is public so consumers can rely on the documented error shape and the
  stable `kind` vocabulary.
  """

  @typedoc "Metadata about the request that produced the error."
  @type request_meta :: %{method: atom() | nil, path: String.t() | nil}

  @typedoc """
  Normalized error map returned by Arex APIs.

  `kind` is the field intended for pattern matching. The remaining fields carry
  human-readable diagnostics and request context.
  """
  @type t :: %{
          kind: atom(),
          message: String.t(),
          status: integer() | nil,
          arcade_code: String.t() | nil,
          details: any(),
          body: map(),
          request: request_meta
        }

  @doc "Builds a normalized error map from an ArcadeDB failure response."
  def arcadedb(message, status, body, request, arcade_code \\ nil, details \\ nil) do
    %{
      kind: :arcadedb,
      message: message,
      status: status,
      arcade_code: arcade_code,
      details: details,
      body: body || %{},
      request: request
    }
  end

  @doc """
  Builds a normalized ArcadeDB error map from a response body.

  Structured bodies contribute `error`, `detail`, and `exception` fields when
  they are present. Plain bodies are wrapped into a minimal map so callers still
  receive a consistent error shape.
  """
  def from_body(status, body, request) when is_map(body) do
    arcadedb(
      body["error"] || body["detail"] || body["exception"] || "ArcadeDB request failed",
      status,
      body,
      request,
      body["exception"],
      body["detail"]
    )
  end

  def from_body(status, body, request) do
    arcadedb("ArcadeDB request failed", status, %{body: body}, request)
  end

  @doc "Builds an error map from a transport-layer exception."
  def transport(exception, request) do
    arcadedb(
      Exception.message(exception),
      nil,
      %{},
      request,
      inspect(exception.__struct__),
      inspect(exception)
    )
  end

  @doc "Returns an error indicating that a database name was required but absent."
  def database_required(request) do
    %{
      kind: :database_required,
      message: "database is required",
      status: nil,
      arcade_code: nil,
      details: nil,
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that a type name was required but absent."
  def type_required(request) do
    %{
      kind: :type_required,
      message: "type is required",
      status: nil,
      arcade_code: nil,
      details: nil,
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that scope cannot be used without tenant."
  def scope_without_tenant(request) do
    %{
      kind: :scope_without_tenant,
      message: "scope requires tenant",
      status: nil,
      arcade_code: nil,
      details: nil,
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that an identifier failed validation."
  def invalid_identifier(identifier, request) do
    %{
      kind: :invalid_identifier,
      message: "invalid identifier: #{identifier}",
      status: nil,
      arcade_code: nil,
      details: %{identifier: identifier},
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that a query or helper matched too many rows."
  def multiple_results(message, request, details \\ nil) do
    %{
      kind: :multiple_results,
      message: message,
      status: nil,
      arcade_code: nil,
      details: details,
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that call options were invalid."
  def bad_opts(message, request, details \\ nil) do
    %{
      kind: :bad_opts,
      message: message,
      status: nil,
      arcade_code: nil,
      details: details,
      body: %{},
      request: request
    }
  end

  @doc "Returns an error indicating that a requested entity was not found."
  def not_found(message, request, details \\ nil) do
    %{
      kind: :not_found,
      message: message,
      status: nil,
      arcade_code: nil,
      details: details,
      body: %{},
      request: request
    }
  end
end
