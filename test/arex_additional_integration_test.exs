defmodule Arex.AdditionalIntegrationTest do
  use Arex.IntegrationCase, async: false

  setup_all do
    db = unique_name("arex_extra_db")

    {:ok, :created} = Arex.Database.create(db)
    {:ok, _} = Arex.Schema.create_document_type("Customer", db: db)
    {:ok, _} = Arex.Schema.create_property("Customer", "external_id", :string, db: db)
    {:ok, _} = Arex.Schema.create_index("Customer", ["external_id"], db: db, unique: true)
    {:ok, _} = Arex.Schema.create_vertex_type("Person", db: db)
    {:ok, _} = Arex.Schema.create_property("Person", "external_id", :string, db: db)
    {:ok, _} = Arex.Schema.create_index("Person", ["external_id"], db: db, unique: true)
    {:ok, _} = Arex.Schema.create_edge_type("Knows", db: db)

    on_exit(fn ->
      _ = Arex.Database.drop(db)
    end)

    %{db: db}
  end

  test "query helpers enforce cardinality and command helpers infer counts", %{db: db} do
    external_id = unique_name("query_customer")
    duplicate_name = unique_name("duplicate")

    assert {:ok, _customer} =
             Arex.Record.persist(
               %{external_id: external_id, name: "Query Customer"},
               customer_opts(db)
             )

    assert {:ok, row} =
             Arex.Query.first(
               "select from Customer where external_id = :external_id",
               %{"external_id" => external_id},
               db: db
             )

    assert row["external_id"] == external_id

    assert {:ok, nil} =
             Arex.Query.first(
               "select from Customer where external_id = :external_id",
               %{"external_id" => unique_name("missing")},
               db: db
             )

    assert {:ok, _} = Arex.Record.persist(%{name: duplicate_name}, customer_opts(db))
    assert {:ok, _} = Arex.Record.persist(%{name: duplicate_name}, customer_opts(db))

    assert {:error, %{kind: :multiple_results}} =
             Arex.Query.one(
               "select from Customer where tenant = :tenant and scope = :scope and name = :name order by @rid",
               %{"tenant" => "ankara", "scope" => "crm", "name" => duplicate_name},
               db: db
             )

    assert {:ok, %{count: count, records: [%{"count" => row_count}]}} =
             Arex.Command.sql(
               "select count(*) as count from Customer where tenant = :tenant and scope = :scope",
               %{"tenant" => "ankara", "scope" => "crm"},
               db: db
             )

    assert is_integer(count)
    assert count == row_count
    assert count >= 3
  end

  test "http helpers work directly against ArcadeDB", %{db: db} do
    assert {:ok, info} = Arex.Http.server_info()
    assert is_binary(info["serverName"])

    assert {:ok, dbs} = Arex.Http.list_databases()
    assert db in dbs
    assert {:ok, true} = Arex.Http.exists_database?(db)

    assert {:ok, rows} =
             Arex.Http.query_raw(
               "select from schema:types where name = :name",
               %{"name" => "Customer"},
               db: db
             )

    assert Enum.any?(rows, &(&1["name"] == "Customer"))

    assert {:ok, [%{"count" => type_count}]} =
             Arex.Http.command_raw("select count(*) as count from schema:types", %{}, db: db)

    assert is_integer(type_count)
    assert type_count >= 3
  end

  test "query and command wrappers cover direct run variants", %{db: db} do
    assert {:ok, [row]} =
             Arex.Query.run(
               "select from schema:types where name = :name",
               %{"name" => "Customer"},
               db: db,
               language: "sql"
             )

    assert row["name"] == "Customer"

    assert {:ok, single_row} =
             Arex.Query.one(
               "select from schema:types where name = :name",
               %{"name" => "Customer"},
               db: db
             )

    assert single_row["name"] == "Customer"

    assert {:ok, nil} =
             Arex.Query.one(
               "select from schema:types where name = :name",
               %{"name" => unique_name("MissingType")},
               db: db
             )

    assert {:ok, %{records: [command_row]}} =
             Arex.Command.run(
               "select from schema:types where name = :name",
               %{"name" => "Customer"},
               db: db,
               language: "sql"
             )

    assert command_row["name"] == "Customer"

    assert {:ok, %{records: [%{"value" => [script_row | _]}]}} =
             Arex.Command.sqlscript(
               "begin; let item0 = select from schema:types where name = 'Customer'; commit; return [$item0];",
               %{},
               db: db
             )

    assert script_row["name"] == "Customer"
  end

  test "record helpers cover persist_new, property mutation, and vaporize", %{db: db} do
    assert {:ok, customer} =
             Arex.Record.persist(
               %{name: "Helper Customer"},
               customer_opts(db)
             )

    rid = customer["@rid"]

    assert {:ok, clone} =
             Arex.Record.persist_new(customer, db: db, tenant: "ankara", scope: "crm")

    assert clone["@rid"] != rid
    assert clone["name"] == customer["name"]

    assert {:ok, "Helper Customer"} =
             Arex.Record.get_property(rid, :name, db: db, tenant: "ankara", scope: "crm")

    assert {:ok, updated} =
             Arex.Record.update_property(rid, :city, "Ankara",
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert updated["city"] == "Ankara"

    assert {:ok, pushed} =
             Arex.Record.push(rid, :tags, "vip", db: db, tenant: "ankara", scope: "crm")

    assert pushed["tags"] == ["vip"]

    assert {:ok, unchanged} =
             Arex.Record.push(rid, :tags, "vip", db: db, tenant: "ankara", scope: "crm")

    assert unchanged["tags"] == ["vip"]

    assert {:ok, popped} =
             Arex.Record.pop(rid, :tags, "vip", db: db, tenant: "ankara", scope: "crm")

    assert popped["tags"] == []

    assert {:ok, still_popped} =
             Arex.Record.pop(rid, :tags, "vip", db: db, tenant: "ankara", scope: "crm")

    assert still_popped["tags"] == []

    assert {:ok, switched_on} =
             Arex.Record.switch_on(rid, :active, db: db, tenant: "ankara", scope: "crm")

    assert switched_on["active"] == true

    assert {:ok, switched_off} =
             Arex.Record.switch_off(rid, :active, db: db, tenant: "ankara", scope: "crm")

    assert switched_off["active"] == false
    assert Arex.Record.rid(customer) == rid
    assert Arex.Record.type(customer) == "Customer"
    assert Arex.Record.category(customer) == "d"

    assert {:ok, :deleted} =
             Arex.Record.vaporize(switched_off, db: db, tenant: "ankara", scope: "crm")

    assert {:error, %{kind: :not_found}} =
             Arex.Record.fetch(rid, db: db, tenant: "ankara", scope: "crm")
  end

  test "record helpers reject invalid inputs and ambiguous matches", %{db: db} do
    duplicate_name = unique_name("ambiguous")

    assert {:error, %{kind: :type_required}} =
             Arex.Record.persist(%{name: "Missing Type"}, db: db)

    assert {:error, %{kind: :scope_without_tenant}} =
             Arex.Record.persist(%{name: "Missing Tenant"},
               db: db,
               type: "Customer",
               scope: "crm"
             )

    assert {:ok, customer} =
             Arex.Record.persist(
               %{external_id: unique_name("invalid_branch"), name: "Invalid Branch"},
               customer_opts(db)
             )

    rid = customer["@rid"]

    assert {:error, %{kind: :bad_opts, message: "type is not allowed when updating by @rid"}} =
             Arex.Record.persist(
               %{"@rid" => rid, "@type" => "Customer", "name" => "Updated"},
               customer_opts(db)
             )

    assert {:error, %{kind: :type_required}} = Arex.Record.get(%{name: "No Type"}, db: db)

    assert {:error, %{kind: :bad_opts, message: "limit must be a positive integer"}} =
             Arex.Record.get(%{name: "No Limit"}, db: db, type: "Customer", limit: 0)

    assert {:error, %{kind: :bad_opts}} =
             Arex.Record.update_property(rid, :tenant, "izmir",
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:error, %{kind: :bad_opts}} =
             Arex.Record.push(rid, :name, "extra", db: db, tenant: "ankara", scope: "crm")

    assert {:error, %{kind: :bad_opts, message: "record must contain @rid"}} =
             Arex.Record.vaporize(%{}, db: db)

    assert {:error, %{kind: :bad_opts, message: "attributes cannot be empty"}} =
             Arex.Record.upsert(
               "Customer",
               %{},
               db: db,
               where: %{external_id: unique_name("upsert_empty")},
               tenant: "ankara",
               scope: "crm"
             )

    assert {:error, %{kind: :bad_opts, message: "where is required"}} =
             Arex.Record.upsert("Customer", %{name: "Missing Where"},
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert {:error, %{kind: :bad_opts, message: "where cannot be empty"}} =
             Arex.Record.upsert("Customer", %{name: "Empty Where"},
               db: db,
               where: %{},
               tenant: "ankara",
               scope: "crm"
             )

    assert {:error, %{kind: :bad_opts, message: "records must be a list"}} =
             Arex.Record.persist_multi(:bad, db: db)

    assert {:ok, _} = Arex.Record.persist(%{name: duplicate_name}, customer_opts(db))
    assert {:ok, _} = Arex.Record.persist(%{name: duplicate_name}, customer_opts(db))

    assert {:error, %{kind: :multiple_results}} =
             Arex.Record.get_one(%{name: duplicate_name}, customer_opts(db))

    assert {:error, %{kind: :multiple_results}} =
             Arex.Record.upsert(
               "Customer",
               %{city: "Ankara"},
               db: db,
               where: %{name: duplicate_name},
               tenant: "ankara",
               scope: "crm"
             )
  end

  test "record batch helpers cover update paths and nil-style lookups", %{db: db} do
    external_id = unique_name("batch_update")

    assert {:ok, existing} =
             Arex.Record.persist(
               %{external_id: external_id, name: "Batch Old"},
               customer_opts(db)
             )

    assert {:ok, [updated, inserted]} =
             Arex.Record.persist_multi(
               [
                 %{"@rid" => existing["@rid"], "name" => "Batch New"},
                 %{
                   "@type" => "Customer",
                   "external_id" => unique_name("batch_insert"),
                   "name" => "Batch Insert"
                 }
               ],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert updated["@rid"] == existing["@rid"]
    assert updated["name"] == "Batch New"
    assert inserted["name"] == "Batch Insert"

    assert {:ok, nil} =
             Arex.Record.get_one(%{external_id: unique_name("missing_lookup")}, customer_opts(db))

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{external_id: unique_name("missing_lookup")},
               customer_opts(db)
             )
  end

  test "record helpers isolate same logical data across tenant and scope boundaries", %{db: db} do
    shared_name = unique_name("isolated_customer")

    assert {:ok, ankara_crm} =
             Arex.Record.persist(
               %{name: shared_name},
               customer_opts(db, "ankara", "crm")
             )

    assert {:ok, ankara_ops} =
             Arex.Record.persist(
               %{name: shared_name},
               customer_opts(db, "ankara", "ops")
             )

    assert {:ok, izmir_crm} =
             Arex.Record.persist(
               %{name: shared_name},
               customer_opts(db, "izmir", "crm")
             )

    assert {:ok, ankara_crm_rows} =
             Arex.Record.get(%{name: shared_name}, customer_opts(db, "ankara", "crm"))

    assert Enum.map(ankara_crm_rows, & &1["@rid"]) == [ankara_crm["@rid"]]

    assert {:ok, ankara_ops_row} =
             Arex.Record.get_one(%{name: shared_name}, customer_opts(db, "ankara", "ops"))

    assert ankara_ops_row["@rid"] == ankara_ops["@rid"]

    assert {:ok, izmir_crm_row} =
             Arex.Record.get_one(%{name: shared_name}, customer_opts(db, "izmir", "crm"))

    assert izmir_crm_row["@rid"] == izmir_crm["@rid"]

    assert {:ok, [visible, nil, nil]} =
             Arex.Record.fetch_multi(
               [ankara_crm["@rid"], ankara_ops["@rid"], izmir_crm["@rid"]],
               db: db,
               tenant: "ankara",
               scope: "crm"
             )

    assert visible["@rid"] == ankara_crm["@rid"]

    assert {:error, %{kind: :not_found}} =
             Arex.Record.fetch(ankara_crm["@rid"], db: db, tenant: "ankara", scope: "ops")

    assert {:error, %{kind: :not_found}} =
             Arex.Record.fetch(ankara_crm["@rid"], db: db, tenant: "izmir", scope: "crm")

    assert {:ok, false} =
             Arex.Record.is_there?(
               %{name: shared_name},
               db: db,
               type: "Customer",
               tenant: "izmir",
               scope: "ops"
             )
  end

  test "schema and database wrappers cover indexes, buckets, and missing objects", %{db: db} do
    property_name = unique_name("nickname")
    bucket_name = unique_name("bucket")
    temp_type = unique_name("TempType")

    assert {:ok, _} = Arex.Schema.create_document_type(temp_type, db: db)
    assert {:ok, :dropped} = Arex.Schema.drop_type(temp_type, db: db)
    assert {:ok, :missing} = Arex.Schema.drop_type(temp_type, db: db)

    assert {:ok, _} = Arex.Schema.create_property("Customer", property_name, :string, db: db)
    assert {:ok, properties} = Arex.Schema.properties("Customer", db: db)
    assert Enum.any?(properties, &(&1["name"] == property_name))
    assert {:ok, nil} = Arex.Schema.type(unique_name("MissingType"), db: db)

    assert {:ok, _} = Arex.Schema.create_index("Customer", [property_name], db: db)
    assert {:ok, customer_indexes} = Arex.Schema.indexes("Customer", db: db)
    assert Enum.any?(customer_indexes, &(&1["name"] == "Customer[external_id]"))
    assert Enum.any?(customer_indexes, &(&1["name"] == "Customer[#{property_name}]"))

    assert {:ok, :dropped} = Arex.Schema.drop_index("Customer[#{property_name}]", db: db)
    assert {:ok, :missing} = Arex.Schema.drop_index("Customer[#{property_name}]", db: db)

    assert {:ok, :dropped} = Arex.Schema.drop_property("Customer", property_name, db: db)
    assert {:ok, :missing} = Arex.Schema.drop_property("Customer", property_name, db: db)

    assert {:ok, all_indexes} = Arex.Schema.indexes(db: db)
    assert Enum.any?(all_indexes, &(&1["typeName"] == "Customer"))

    assert {:ok, _} = Arex.Schema.create_bucket(bucket_name, db: db)
    assert {:ok, bucket} = Arex.Schema.bucket(bucket_name, db: db)
    assert bucket["name"] == bucket_name
    assert {:ok, nil} = Arex.Schema.bucket(unique_name("MissingBucket"), db: db)

    assert {:ok, buckets} = Arex.Schema.buckets(db: db)
    assert Enum.any?(buckets, &(&1["name"] == bucket_name))

    assert {:ok, :dropped} = Arex.Schema.drop_bucket(bucket_name, db: db)
    assert {:ok, :missing} = Arex.Schema.drop_bucket(bucket_name, db: db)

    assert {:ok, stats} = Arex.Database.stats(db, [])
    assert stats.db == db
    assert stats.type_count >= 3

    missing_db = unique_name("missingdb")
    assert {:ok, false} = Arex.Database.exists?(missing_db)
    assert {:ok, :missing} = Arex.Database.drop(missing_db)
  end

  test "database create and drop transitions a dedicated database" do
    db_name = unique_name("lifecycle_db")

    assert {:ok, false} = Arex.Database.exists?(db_name)
    assert {:ok, :created} = Arex.Database.create(db_name)
    assert {:ok, true} = Arex.Database.exists?(db_name)
    assert {:ok, :dropped} = Arex.Database.drop(db_name)
    assert {:ok, false} = Arex.Database.exists?(db_name)
  end

  test "vertex and edge wrappers cover inbound traversal, replace, and delete", %{db: db} do
    bob_external_id = unique_name("bob")

    assert {:ok, alice} =
             Arex.Vertex.create(
               "Person",
               %{name: "Alice"},
               graph_opts(db)
             )

    assert {:ok, bob} =
             Arex.Vertex.upsert(
               "Person",
               %{name: "Bob"},
               db: db,
               where: %{external_id: bob_external_id},
               tenant: "ankara",
               scope: "graph"
             )

    assert {:ok, fetched_alice} = Arex.Vertex.fetch(alice["@rid"], graph_opts(db))
    assert fetched_alice["name"] == "Alice"

    assert {:ok, merged_bob} =
             Arex.Vertex.merge(bob["@rid"], %{city: "Ankara"}, graph_opts(db))

    assert merged_bob["city"] == "Ankara"

    assert {:ok, replaced_bob} =
             Arex.Vertex.replace(bob["@rid"], %{name: "Bobby"}, graph_opts(db))

    assert replaced_bob["name"] == "Bobby"

    assert {:ok, edge} =
             Arex.Edge.create(
               "Knows",
               alice["@rid"],
               bob["@rid"],
               %{since: 2024},
               graph_opts(db)
             )

    assert {:ok, fetched_edge} = Arex.Edge.fetch(edge["@rid"], graph_opts(db))
    assert fetched_edge["since"] == 2024
    assert Arex.Edge.out_rid(edge) == alice["@rid"]
    assert Arex.Edge.in_rid(edge) == bob["@rid"]

    assert {:ok, incoming} = Arex.Vertex.incoming(bob["@rid"], nil, graph_opts(db))
    assert Enum.any?(incoming, &(&1["@rid"] == alice["@rid"]))

    assert {:ok, both} = Arex.Vertex.both(alice["@rid"], "Knows", graph_opts(db))
    assert Enum.any?(both, &(&1["@rid"] == bob["@rid"]))

    assert {:ok, edges} = Arex.Edge.between(alice["@rid"], bob["@rid"], nil, graph_opts(db))
    assert Enum.any?(edges, &(&1["@rid"] == edge["@rid"]))

    assert {:ok, :deleted} = Arex.Edge.delete(edge["@rid"], graph_opts(db))
    assert {:error, %{kind: :not_found}} = Arex.Edge.fetch(edge["@rid"], graph_opts(db))

    assert {:ok, :deleted} = Arex.Vertex.delete(alice["@rid"], graph_opts(db))
    assert {:ok, :deleted} = Arex.Vertex.delete(bob["@rid"], graph_opts(db))
  end

  test "graph helpers enforce tenant and scope isolation", %{db: db} do
    shared_name = unique_name("graph_person")

    assert {:ok, ankara_graph_alice} =
             Arex.Vertex.create(
               "Person",
               %{external_id: unique_name("ankara_graph_alice"), name: shared_name},
               graph_opts(db, "ankara", "graph")
             )

    assert {:ok, ankara_graph_bob} =
             Arex.Vertex.create(
               "Person",
               %{external_id: unique_name("ankara_graph_bob"), name: shared_name},
               graph_opts(db, "ankara", "graph")
             )

    assert {:ok, ankara_alt_alice} =
             Arex.Vertex.create(
               "Person",
               %{external_id: unique_name("ankara_alt_alice"), name: shared_name},
               graph_opts(db, "ankara", "graph_alt")
             )

    assert {:ok, izmir_graph_alice} =
             Arex.Vertex.create(
               "Person",
               %{external_id: unique_name("izmir_graph_alice"), name: shared_name},
               graph_opts(db, "izmir", "graph")
             )

    assert {:ok, edge} =
             Arex.Edge.create(
               "Knows",
               ankara_graph_alice["@rid"],
               ankara_graph_bob["@rid"],
               %{since: 2026},
               graph_opts(db, "ankara", "graph")
             )

    assert {:ok, neighbors} =
             Arex.Vertex.out(ankara_graph_alice["@rid"], nil, graph_opts(db, "ankara", "graph"))

    assert Enum.map(neighbors, & &1["@rid"]) == [ankara_graph_bob["@rid"]]

    assert {:ok, incoming} =
             Arex.Vertex.incoming(
               ankara_graph_bob["@rid"],
               nil,
               graph_opts(db, "ankara", "graph")
             )

    assert Enum.map(incoming, & &1["@rid"]) == [ankara_graph_alice["@rid"]]

    assert {:ok, same_scope_edges} =
             Arex.Edge.between(
               ankara_graph_alice["@rid"],
               ankara_graph_bob["@rid"],
               nil,
               graph_opts(db, "ankara", "graph")
             )

    assert Enum.map(same_scope_edges, & &1["@rid"]) == [edge["@rid"]]

    assert {:error, %{kind: :not_found}} =
             Arex.Vertex.fetch(ankara_graph_alice["@rid"], graph_opts(db, "ankara", "graph_alt"))

    assert {:error, %{kind: :not_found}} =
             Arex.Vertex.fetch(ankara_graph_alice["@rid"], graph_opts(db, "izmir", "graph"))

    assert {:error, %{kind: :not_found}} =
             Arex.Edge.fetch(edge["@rid"], graph_opts(db, "ankara", "graph_alt"))

    assert {:error, %{kind: :not_found}} =
             Arex.Vertex.out(
               ankara_graph_alice["@rid"],
               nil,
               graph_opts(db, "ankara", "graph_alt")
             )

    assert {:error, %{kind: :not_found}} =
             Arex.Edge.between(
               ankara_graph_alice["@rid"],
               ankara_graph_bob["@rid"],
               nil,
               graph_opts(db, "izmir", "graph")
             )

    assert {:ok, ankara_alt_fetch} =
             Arex.Vertex.fetch(ankara_alt_alice["@rid"], graph_opts(db, "ankara", "graph_alt"))

    assert ankara_alt_fetch["@rid"] == ankara_alt_alice["@rid"]

    assert {:ok, izmir_graph_fetch} =
             Arex.Vertex.fetch(izmir_graph_alice["@rid"], graph_opts(db, "izmir", "graph"))

    assert izmir_graph_fetch["@rid"] == izmir_graph_alice["@rid"]
  end

  defp customer_opts(db) do
    [db: db, type: "Customer", tenant: "ankara", scope: "crm"]
  end

  defp customer_opts(db, tenant, scope) do
    [db: db, type: "Customer", tenant: tenant, scope: scope]
  end

  defp graph_opts(db) do
    [db: db, tenant: "ankara", scope: "graph"]
  end

  defp graph_opts(db, tenant, scope) do
    [db: db, tenant: tenant, scope: scope]
  end
end
