defmodule Arex.Database do
  @moduledoc """
  Database-level administrative helpers.

  These functions operate on ArcadeDB databases themselves rather than records
  inside a database. They are typically used in setup, provisioning, test
  workflows, and lightweight operational inspection.

  Reach for this module when you need to create or drop databases, check server
  visibility, or collect a compact type summary for a target database.

  This module stays narrow on purpose. It does not try to expose every
  server-level administrative operation, only the ones that are common in test
  setup, local development, and operational checks.
  """

  alias Arex.Http
  alias Arex.Query
  alias Arex.Sql

  @doc """
  Lists database names visible to the configured ArcadeDB server credentials.
  """
  def list(opts \\ []) do
    Http.list_databases(opts)
  end

  @doc """
  Creates a database and returns `{:ok, :created}` on success.

  The database name is validated before the command is sent to ArcadeDB.
  """
  def create(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name),
         {:ok, _result} <- Http.server_command("create database #{name}", opts) do
      {:ok, :created}
    end
  end

  @doc """
  Drops a database when it exists.

  Returns `{:ok, :missing}` when the database does not exist.
  """
  def drop(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name),
         {:ok, exists?} <- exists?(name, opts) do
      if exists? do
        case Http.server_command("drop database #{name}", opts) do
          {:ok, _result} -> {:ok, :dropped}
          {:error, error} -> {:error, error}
        end
      else
        {:ok, :missing}
      end
    end
  end

  @doc """
  Returns whether the named database exists.

  This checks the server-scoped existence endpoint rather than querying inside
  the database.
  """
  def exists?(name, opts \\ []) do
    with {:ok, name} <- Sql.validate_identifier(name) do
      Http.exists_database?(name, opts)
    end
  end

  @doc """
  Returns a lightweight summary for the current database in `opts`.

  The result includes `:type_count` and the raw type rows returned from
  `schema:types`.
  """
  def stats(opts) when is_list(opts) do
    with {:ok, types} <- Query.sql("select from schema:types order by name", %{}, opts) do
      {:ok, %{type_count: length(types), types: types}}
    end
  end

  @doc """
  Returns a lightweight summary for the named database.

  This variant injects `db: name` into the query options before loading
  `schema:types`.
  """
  def stats(name, opts) do
    Query.sql(
      "select from schema:types order by name",
      %{},
      Keyword.put(opts, :db, to_string(name))
    )
    |> case do
      {:ok, types} -> {:ok, %{db: to_string(name), type_count: length(types), types: types}}
      {:error, error} -> {:error, error}
    end
  end
end
