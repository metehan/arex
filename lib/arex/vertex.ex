defmodule Arex.Vertex do
  @moduledoc """
  Graph vertex helpers with boundary-aware traversal.

  This module builds vertex creation and traversal operations on top of the core
  record, query, and command helpers while preserving tenant and scope
  boundaries.

  Use `Arex.Vertex` when your application works with ArcadeDB vertex types but
  still wants the same ergonomics as `Arex.Record`: validated identifiers,
  normalized errors, boundary stamping on writes, and boundary filtering on
  reads and traversals.

  In practice this module is a thin, focused graph layer over the record and
  query primitives. It exists so graph code can stay as concise and explicit as
  document code without losing the tenant/scope model.
  """

  alias Arex.Command
  alias Arex.Options
  alias Arex.Query
  alias Arex.Record
  alias Arex.Sql

  @doc """
  Creates a vertex and stamps any active tenant and scope values.

  The type name is validated before Arex sends the `create vertex` command.
  """
  def create(type, attrs, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, type} <- Sql.validate_identifier(type),
         {:ok, attrs} <- Sql.normalize_map(attrs),
         content = Sql.stamp_boundaries(attrs, resolved),
         {:ok, %{records: [record | _]}} <-
           Command.sql("create vertex #{type} content #{Sql.json_map(content)}", %{}, resolved) do
      {:ok, record}
    end
  end

  @doc "Fetches a vertex by RID using the same boundary rules as `Arex.Record.fetch/2`."
  def fetch(rid, opts \\ []), do: Record.fetch(rid, opts)
  @doc "Deletes a vertex by RID after confirming it is visible within the active boundary."
  def delete(rid, opts \\ []), do: Record.vaporize_by_id(rid, opts)
  @doc "Merges attributes into a vertex and re-fetches the updated record."
  def merge(rid, attrs, opts \\ []), do: Record.merge(rid, attrs, opts)
  @doc "Replaces a vertex content payload while preserving its current boundary fields."
  def replace(rid, attrs, opts \\ []), do: Record.replace(rid, attrs, opts)

  @doc "Upserts a vertex type using the same cardinality and boundary rules as `Arex.Record.upsert/3`."
  def upsert(type, attrs, opts \\ []), do: Record.upsert(type, attrs, opts)

  @doc "Traverses outgoing neighbor vertices, optionally restricted by edge type."
  def out(rid, edge_type \\ nil, opts \\ []), do: traverse(rid, edge_type, :out, opts)
  @doc "Traverses incoming neighbor vertices, optionally restricted by edge type."
  def incoming(rid, edge_type \\ nil, opts \\ []), do: traverse(rid, edge_type, :in, opts)

  @doc "Traverses both incoming and outgoing neighbor vertices, optionally restricted by edge type."
  def both(rid, edge_type \\ nil, opts \\ []), do: traverse(rid, edge_type, :both, opts)

  defp traverse(rid, edge_type, direction, opts) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, rid} <- Sql.validate_rid(rid),
         {:ok, _source} <- Record.fetch(rid, resolved),
         {:ok, call} <- traversal_call(direction, edge_type),
         {:ok, rows} <- Query.sql("select expand(#{call}) from #{rid}", %{}, resolved) do
      {:ok, Enum.filter(rows, &Sql.matches_boundary?(&1, resolved))}
    end
  end

  defp traversal_call(direction, nil), do: {:ok, "#{direction}()"}

  defp traversal_call(direction, edge_type) do
    with {:ok, edge_type} <- Sql.validate_identifier(edge_type) do
      {:ok, "#{direction}('#{edge_type}')"}
    end
  end
end
