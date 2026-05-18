defmodule Arex.IntegrationTest do
  use Arex.IntegrationCase, async: false

  setup_all do
    db = unique_name("arex_test_db")

    {:ok, :created} = Arex.Database.create(db)
    {:ok, _} = Arex.Schema.create_document_type("Customer", db: db)
    {:ok, _} = Arex.Schema.create_property("Customer", "external_id", :string, db: db)
    {:ok, _} = Arex.Schema.create_index("Customer", ["external_id"], db: db, unique: true)
    {:ok, _} = Arex.Schema.create_vertex_type("Person", db: db)
    {:ok, _} = Arex.Schema.create_edge_type("Knows", db: db)

    on_exit(fn ->
      _ = Arex.Database.drop(db)
    end)

    %{db: db}
  end

  test "server info, query, paging, and streaming work against Imported" do
    assert {:ok, :pong} = Arex.ping()
    assert {:ok, info} = Arex.server_info()
    assert is_binary(info["serverName"])
    assert is_binary(info["version"])

    assert {:ok, dbs} = Arex.Database.list()
    assert "Imported" in dbs
    assert {:ok, true} = Arex.Database.exists?("Imported")

    assert {:ok, [beer]} =
             Arex.Query.sql("select from Beer where id = :id", %{"id" => 1}, db: "Imported")

    assert beer["@type"] == "Beer"
    assert beer["name"] == "Hocus Pocus"

    assert {:ok, page} =
             Arex.Query.page("select from Beer order by id", %{},
               db: "Imported",
               limit: 2,
               offset: 0
             )

    assert length(page.entries) == 2
    assert page.count == 2
    assert page.has_more?

    assert {:ok, stream} =
             Arex.Query.stream_pages("select from Beer order by id", %{},
               db: "Imported",
               limit: 2
             )

    pages = Enum.take(stream, 2)

    assert Enum.all?(pages, fn
             {:ok, %{entries: entries}} when is_list(entries) -> true
             _other -> false
           end)
  end

  test "command helpers execute raw SQL and reject chunk_size", %{db: db} do
    assert {:error, %{kind: :bad_opts}} =
             Arex.Command.sql("select from Customer", %{}, db: db, chunk_size: 500)

    assert {:ok, %{records: rows}} =
             Arex.Command.sql(
               "select from schema:types where name = :name",
               %{"name" => "Customer"},
               db: db
             )

    assert Enum.any?(rows, &(&1["name"] == "Customer"))
  end

  test "schema and database wrappers work", %{db: db} do
    assert {:ok, types} = Arex.Schema.types(db: db)
    assert Enum.any?(types, &(&1["name"] == "Customer"))

    assert {:ok, customer_type} = Arex.Schema.type("Customer", db: db)
    assert customer_type["name"] == "Customer"

    assert {:ok, properties} = Arex.Schema.properties("Customer", db: db)
    assert Enum.any?(properties, &(&1["name"] == "external_id"))

    assert {:ok, stats} = Arex.Database.stats(db: db)
    assert stats.type_count >= 3
  end

  test "record helpers round-trip data and enforce boundaries", %{db: db} do
    assert {:ok, customer} =
             Arex.Record.persist(
               %{name: "Alice"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    rid = customer["@rid"]
    assert customer["tenant"] == "ankara"
    assert customer["scope"] == "crm"

    assert {:ok, same_customer} =
             Arex.Record.fetch(rid, db: db, tenant: "ankara", scope: "crm")

    assert same_customer["name"] == "Alice"

    assert {:ok, [fetched, nil]} =
             Arex.Record.fetch_multi(
               [rid, "#999999:999999"],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert fetched["@rid"] == rid

    assert {:ok, customer_from_get} =
             Arex.Record.get_one(
               %{name: "Alice"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert customer_from_get["@rid"] == rid

    assert {:ok, true} =
             Arex.Record.is_there?(
               %{name: "Alice"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, merged} =
             Arex.Record.merge(rid, %{city: "Ankara"}, db: db, tenant: "ankara", scope: "crm")

    assert merged["city"] == "Ankara"

    assert {:ok, replaced} =
             Arex.Record.replace(
               rid,
               %{name: "Alice Updated"},
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert replaced["name"] == "Alice Updated"
    refute Map.has_key?(replaced, "city")

    assert {:ok, upserted_1} =
             Arex.Record.upsert(
               "Customer",
               %{name: "Bob"},
               db: db,
               where: %{external_id: "cust-1"},
               tenant: "ankara",
               scope: "crm"
             )

    assert upserted_1["external_id"] == "cust-1"

    assert {:ok, upserted_2} =
             Arex.Record.upsert(
               "Customer",
               %{name: "Bob Updated"},
               db: db,
               where: %{external_id: "cust-1"},
               tenant: "ankara",
               scope: "crm"
             )

    assert upserted_2["name"] == "Bob Updated"

    assert {:error, %{kind: :not_found}} =
             Arex.Record.fetch(rid, db: db, tenant: "izmir", scope: "crm")

    assert {:ok, :deleted} =
             Arex.Record.vaporize_by_id(rid, db: db, tenant: "ankara", scope: "crm")

    assert {:error, %{kind: :not_found}} =
             Arex.Record.fetch(rid, db: db, tenant: "ankara", scope: "crm")
  end

  test "persist_multi is atomic", %{db: db} do
    assert {:ok, [one, two]} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => "batch-a", "name" => "A"},
                 %{"@type" => "Customer", "external_id" => "batch-b", "name" => "B"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert one["external_id"] == "batch-a"
    assert two["external_id"] == "batch-b"

    assert {:error, _error} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => "batch-c", "name" => "C"},
                 %{"@type" => "Customer", "external_id" => "batch-c", "name" => "D"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{external_id: "batch-c"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )
  end

  test "vertex and edge helpers work", %{db: db} do
    assert {:ok, alice} =
             Arex.Vertex.create(
               "Person",
               %{name: "Alice"},
               db: db,
               tenant: "ankara",
               scope: "graph"
             )

    assert {:ok, bob} =
             Arex.Vertex.create(
               "Person",
               %{name: "Bob"},
               db: db,
               tenant: "ankara",
               scope: "graph"
             )

    assert {:ok, edge} =
             Arex.Edge.create(
               "Knows",
               alice["@rid"],
               bob["@rid"],
               %{},
               db: db,
               tenant: "ankara",
               scope: "graph"
             )

    assert edge["@type"] == "Knows"

    assert {:ok, neighbors} =
             Arex.Vertex.out(
               alice["@rid"],
               "Knows",
               db: db,
               tenant: "ankara",
               scope: "graph"
             )

    assert Enum.any?(neighbors, &(&1["@rid"] == bob["@rid"]))

    assert {:ok, edges} =
             Arex.Edge.between(
               alice["@rid"],
               bob["@rid"],
               "Knows",
               db: db,
               tenant: "ankara",
               scope: "graph"
             )

    assert Enum.any?(edges, &(&1["@rid"] == edge["@rid"]))
  end
end
