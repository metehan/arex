defmodule Arex.Edge do
  @moduledoc """
  Graph edge helpers with tenant and scope awareness.

  Edges are created and queried with the same tenant and scope boundary rules as
  records and vertices.

  Use this module when your relationship data is naturally represented as
  ArcadeDB edges and you want Arex to validate vertex visibility, stamp active
  boundaries, and normalize RID-oriented operations.
  """

  alias Arex.Command
  alias Arex.Options
  alias Arex.Query
  alias Arex.Record
  alias Arex.Sql

  @doc """
  Creates an edge between two existing vertices.

  Both endpoint RIDs must be valid and visible within the active boundary
  before the edge is created.
  """
  def create(edge_type, from_rid, to_rid, attrs \\ %{}, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, edge_type} <- Sql.validate_identifier(edge_type),
         {:ok, from_rid} <- Sql.validate_rid(from_rid),
         {:ok, to_rid} <- Sql.validate_rid(to_rid),
         {:ok, _from} <- Record.fetch(from_rid, resolved),
         {:ok, _to} <- Record.fetch(to_rid, resolved),
         {:ok, attrs} <- Sql.normalize_map(attrs),
         content = Sql.stamp_boundaries(attrs, resolved),
         {:ok, %{records: [record | _]}} <-
           Command.sql(
             "create edge #{edge_type} from #{from_rid} to #{to_rid} content #{Sql.json_map(content)}",
             %{},
             resolved
           ) do
      {:ok, record}
    end
  end

  @doc "Fetches an edge by RID using the same boundary rules as record fetches."
  def fetch(rid, opts \\ []), do: Record.fetch(rid, opts)
  @doc "Deletes an edge by RID after confirming it is visible within the active boundary."
  def delete(rid, opts \\ []), do: Record.vaporize_by_id(rid, opts)

  @doc """
  Finds edges from one vertex RID to another, optionally restricted by edge type.

  Returned rows are filtered to the active tenant and scope boundary.
  """
  def between(from_rid, to_rid, edge_type \\ nil, opts \\ []) do
    with {:ok, resolved} <- Options.resolve(opts),
         {:ok, from_rid} <- Sql.validate_rid(from_rid),
         {:ok, to_rid} <- Sql.validate_rid(to_rid),
         {:ok, _from} <- Record.fetch(from_rid, resolved),
         {:ok, _to} <- Record.fetch(to_rid, resolved),
         {:ok, call} <- traversal_call(edge_type),
         {:ok, rows} <- Query.sql("select expand(#{call}) from #{from_rid}", %{}, resolved) do
      rows
      |> Enum.filter(fn row -> row["@in"] == to_rid and Sql.matches_boundary?(row, resolved) end)
      |> then(&{:ok, &1})
    end
  end

  @doc "Extracts the outgoing RID from an edge record."
  def out_rid(edge_record) when is_map(edge_record),
    do: edge_record["@out"] || edge_record[:"@out"]

  def out_rid(_edge_record), do: nil

  @doc "Extracts the incoming RID from an edge record."
  def in_rid(edge_record) when is_map(edge_record), do: edge_record["@in"] || edge_record[:"@in"]
  def in_rid(_edge_record), do: nil

  defp traversal_call(nil), do: {:ok, "outE()"}

  defp traversal_call(edge_type) do
    with {:ok, edge_type} <- Sql.validate_identifier(edge_type) do
      {:ok, "outE('#{edge_type}')"}
    end
  end
end
