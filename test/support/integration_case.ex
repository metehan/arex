defmodule Arex.IntegrationCase do
  use ExUnit.CaseTemplate

  alias Arex.Schema

  using do
    quote do
      import Arex.IntegrationCase
    end
  end

  setup do
    Application.put_env(:arex, :url, System.get_env("AREX_URL") || "http://localhost:2480/")
    Application.put_env(:arex, :user, System.get_env("AREX_USER") || "test_user")
    Application.put_env(:arex, :pwd, System.get_env("AREX_PWD") || "test_password")
    Application.put_env(:arex, :db, System.get_env("AREX_DB") || "test_db")
    Application.put_env(:arex, :language, "sql")
    :ok
  end

  def unique_name(prefix) do
    "#{prefix}_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
  end

  def base_db do
    System.get_env("AREX_DB") || "test_db"
  end

  def ensure_base_schema(db) do
    ensure_type(db, "Customer", &Schema.create_document_type/2)
    ensure_property(db, "Customer", "external_id", :string)
    ensure_index(db, "Customer", ["external_id"], unique: true)

    ensure_type(db, "Person", &Schema.create_vertex_type/2)
    ensure_property(db, "Person", "external_id", :string)
    ensure_index(db, "Person", ["external_id"], unique: true)

    ensure_type(db, "Knows", &Schema.create_edge_type/2)

    :ok
  end

  defp ensure_type(db, type_name, creator) do
    case Schema.type(type_name, db: db) do
      {:ok, nil} ->
        {:ok, _} = creator.(type_name, db: db)
        :ok

      {:ok, _type} ->
        :ok
    end
  end

  defp ensure_property(db, type_name, property_name, property_type) do
    case Schema.properties(type_name, db: db) do
      {:ok, properties} ->
        if Enum.any?(properties, &(&1["name"] == property_name)) do
          :ok
        else
          {:ok, _} = Schema.create_property(type_name, property_name, property_type, db: db)
          :ok
        end
    end
  end

  defp ensure_index(db, type_name, fields, opts) do
    index_name = "#{type_name}[#{Enum.join(fields, ",")}]"

    case Schema.indexes(type_name, db: db) do
      {:ok, indexes} ->
        if Enum.any?(indexes, &(&1["name"] == index_name)) do
          :ok
        else
          {:ok, _} = Schema.create_index(type_name, fields, Keyword.put(opts, :db, db))
          :ok
        end
    end
  end
end
