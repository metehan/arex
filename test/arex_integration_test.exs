defmodule Arex.IntegrationTest do
  use Arex.IntegrationCase, async: false

  setup_all do
    db = base_db()
    :ok = ensure_base_schema(db)

    %{db: db}
  end

  test "server info, query, paging, and streaming work against a provisioned test database", %{
    db: db
  } do
    prefix = unique_name("stream")
    stream_1 = "#{prefix}_1"
    stream_2 = "#{prefix}_2"
    stream_3 = "#{prefix}_3"

    assert {:ok, :pong} = Arex.ping()
    assert {:ok, info} = Arex.server_info()
    assert is_binary(info["serverName"])
    assert is_binary(info["version"])

    assert {:ok, dbs} = Arex.Database.list()
    assert db in dbs
    assert {:ok, true} = Arex.Database.exists?(db)

    assert {:ok, _alice} =
             Arex.Record.persist(
               %{external_id: stream_1, name: "Alice"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, _bob} =
             Arex.Record.persist(
               %{external_id: stream_2, name: "Bob"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, _carol} =
             Arex.Record.persist(
               %{external_id: stream_3, name: "Carol"},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, [customer]} =
             Arex.Query.sql(
               "select from Customer where external_id = :external_id",
               %{"external_id" => stream_1},
               db: db
             )

    assert customer["@type"] == "Customer"
    assert customer["name"] == "Alice"

    assert {:ok, page} =
             Arex.Query.page(
               "select from Customer where external_id like :prefix order by external_id",
               %{"prefix" => "#{prefix}%"},
               db: db,
               limit: 2,
               offset: 0
             )

    assert length(page.entries) == 2
    assert page.count == 2
    assert page.has_more?

    assert {:ok, stream} =
             Arex.Query.stream_pages(
               "select from Customer where external_id like :prefix order by external_id",
               %{"prefix" => "#{prefix}%"},
               db: db,
               limit: 2
             )

    pages = Enum.take(stream, 2)

    assert Enum.all?(pages, fn
             {:ok, %{entries: entries}} when is_list(entries) -> true
             _other -> false
           end)
  end

  test "command helpers execute raw SQL", %{db: db} do
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
    customer_name = unique_name("alice")
    updated_name = unique_name("alice_updated")
    upsert_external_id = unique_name("cust")

    assert {:ok, customer} =
             Arex.Record.persist(
               %{name: customer_name},
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

    assert same_customer["name"] == customer_name

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
               %{name: customer_name},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert customer_from_get["@rid"] == rid

    assert {:ok, true} =
             Arex.Record.is_there?(
               %{name: customer_name},
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
               %{name: updated_name},
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert replaced["name"] == updated_name
    refute Map.has_key?(replaced, "city")

    assert {:ok, upserted_1} =
             Arex.Record.upsert(
               "Customer",
               %{name: "Bob"},
               db: db,
               where: %{external_id: upsert_external_id},
               tenant: "ankara",
               scope: "crm"
             )

    assert upserted_1["external_id"] == upsert_external_id

    assert {:ok, upserted_2} =
             Arex.Record.upsert(
               "Customer",
               %{name: "Bob Updated"},
               db: db,
               where: %{external_id: upsert_external_id},
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
    batch_prefix = unique_name("batch")
    batch_a = "#{batch_prefix}_a"
    batch_b = "#{batch_prefix}_b"
    batch_c = "#{batch_prefix}_c"

    assert {:ok, [one, two]} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => batch_a, "name" => "A"},
                 %{"@type" => "Customer", "external_id" => batch_b, "name" => "B"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert one["external_id"] == batch_a
    assert two["external_id"] == batch_b

    assert {:error, _error} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => batch_c, "name" => "C"},
                 %{"@type" => "Customer", "external_id" => batch_c, "name" => "D"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{external_id: batch_c},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )
  end

  test "persist_multi rolls back when a later update cannot run", %{db: db} do
    boundary_insert = unique_name("batch_boundary_insert")

    assert {:ok, boundary_record} =
             Arex.Record.persist(
               %{
                 external_id: unique_name("batch_boundary_existing"),
                 name: "Boundary Existing"
               },
               db: db,
               type: "Customer",
               tenant: "izmir",
               scope: "crm"
             )

    assert {:error, %{kind: :not_found}} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => boundary_insert, "name" => "Rollback"},
                 %{"@rid" => boundary_record["@rid"], "name" => "Should Not Update"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{external_id: boundary_insert},
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, untouched} =
             Arex.Record.fetch(boundary_record["@rid"],
               db: db,
               tenant: "izmir",
               scope: "crm"
             )

    assert untouched["name"] == "Boundary Existing"

    deleted_insert = unique_name("batch_deleted_insert")

    assert {:ok, deleted_record} =
             Arex.Record.persist(
               %{
                 external_id: unique_name("batch_deleted_existing"),
                 name: "Deleted Existing"
               },
               db: db,
               type: "Customer",
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, :deleted} =
             Arex.Record.vaporize_by_id(deleted_record["@rid"],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:error, %{kind: :not_found}} =
             Arex.Record.persist_multi(
               [
                 %{"@type" => "Customer", "external_id" => deleted_insert, "name" => "Rollback"},
                 %{"@rid" => deleted_record["@rid"], "name" => "Should Not Update"}
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{external_id: deleted_insert},
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
