defmodule Arex.UnitTest do
  use ExUnit.Case, async: false

  alias Arex.Command
  alias Arex.Database
  alias Arex.Edge
  alias Arex.Error
  alias Arex.Http
  alias Arex.Options
  alias Arex.Query
  alias Arex.Record
  alias Arex.Schema
  alias Arex.Sql
  alias Arex.Vertex

  setup do
    app_env = Application.get_all_env(:arex)

    system_env =
      Enum.into(["AREX_URL", "AREX_USER", "AREX_PWD", "AREX_DB"], %{}, fn key ->
        {key, System.get_env(key)}
      end)

    clear_arex_env()
    Enum.each(system_env, fn {key, _value} -> System.delete_env(key) end)

    on_exit(fn ->
      clear_arex_env()

      Enum.each(app_env, fn {key, value} ->
        Application.put_env(:arex, key, value)
      end)

      Enum.each(system_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "error constructors build normalized maps" do
    request = %{method: :post, path: "/api/v1/query/example"}

    assert %{
             kind: :arcadedb,
             message: "ArcadeDB failed",
             status: 500,
             arcade_code: "SchemaException",
             details: "bad input",
             body: %{"detail" => "bad input"},
             request: ^request
           } =
             Error.arcadedb(
               "ArcadeDB failed",
               500,
               %{"detail" => "bad input"},
               request,
               "SchemaException",
               "bad input"
             )

    assert %{
             kind: :arcadedb,
             message: "missing row",
             status: 404,
             arcade_code: "com.arcadedb.exception.RecordNotFoundException",
             details: "RID not found"
           } =
             Error.from_body(
               404,
               %{
                 "error" => "missing row",
                 "detail" => "RID not found",
                 "exception" => "com.arcadedb.exception.RecordNotFoundException"
               },
               request
             )

    assert %{kind: :arcadedb, body: %{body: "plain-text"}} =
             Error.from_body(500, "plain-text", request)

    assert %{kind: :arcadedb, message: "boom", arcade_code: "RuntimeError", request: ^request} =
             Error.transport(%RuntimeError{message: "boom"}, request)

    assert %{kind: :database_required} = Error.database_required(request)
    assert %{kind: :type_required} = Error.type_required(request)
    assert %{kind: :scope_without_tenant} = Error.scope_without_tenant(request)

    assert %{kind: :invalid_identifier, details: %{identifier: "bad-name"}} =
             Error.invalid_identifier("bad-name", request)

    assert %{kind: :multiple_results, details: %{limit: 2}} =
             Error.multiple_results("too many", request, %{limit: 2})

    assert %{kind: :transaction_required, details: %{mode: :required}} =
             Error.transaction_required("transaction needed", request, %{mode: :required})

    assert %{kind: :bad_opts, details: %{key: :tenant}} =
             Error.bad_opts("bad option", request, %{key: :tenant})

    assert %{kind: :not_found, details: %{rid: "#12:0"}} =
             Error.not_found("missing", request, %{rid: "#12:0"})
  end

  test "options resolve merges config and env values and sanitizes request options" do
    Application.put_env(:arex, :url, "http://config.example")
    Application.put_env(:arex, :user, :root)
    Application.put_env(:arex, :pwd, :secret)
    Application.put_env(:arex, :db, :config_db)
    Application.put_env(:arex, :language, "sqlscript")

    assert {:ok, resolved} =
             Options.resolve(
               db: "call_db",
               tenant: :ankara,
               scope: "crm",
               type: :Customer,
               transaction: :required,
               transaction_timeout: 2_000,
               receive_timeout: 7_500,
               retry: [max: 2, backoff_ms: 10],
               headers: [x_trace_id: 123, authorization: "ignore-me"],
               req_options: %{retry: true, max_retries: 9, pool_timeout: 111}
             )

    assert resolved.url == "http://config.example"
    assert resolved.user == "root"
    assert resolved.pwd == "secret"
    assert resolved.db == "call_db"
    assert resolved.language == "sqlscript"
    assert resolved.type == "Customer"
    assert resolved.tenant == "ankara"
    assert resolved.scope == "crm"
    assert resolved.transaction == :required
    assert resolved.transaction_timeout == 2_000
    assert resolved.receive_timeout == 7_500
    assert resolved.retry == [max: 2, backoff_ms: 10]
    assert resolved.headers == %{"x-trace-id" => "123"}
    assert resolved.req_options == [pool_timeout: 111]
  end

  test "options default language to sql when call opts and config omit it" do
    Application.put_env(:arex, :url, "http://config.example")
    Application.put_env(:arex, :user, :root)
    Application.put_env(:arex, :pwd, :secret)
    Application.put_env(:arex, :db, :config_db)

    assert {:ok, resolved} = Options.resolve([])
    assert resolved.language == "sql"
  end

  test "options reject invalid values" do
    assert {:error, %{kind: :bad_opts, message: "options must be a keyword list"}} =
             Options.resolve(%{})

    assert {:error, %{kind: :scope_without_tenant}} =
             Options.resolve(scope: "crm")

    assert {:error, %{kind: :bad_opts, message: "transaction must be :auto, :required, or false"}} =
             Options.resolve(transaction: :sometimes)

    assert {:error, %{kind: :bad_opts, message: "receive_timeout must be a positive integer"}} =
             Options.resolve(receive_timeout: 0)

    assert {:error,
            %{
              kind: :bad_opts,
              message:
                "retry must be false or a keyword list with non-negative max and backoff_ms"
            }} =
             Options.resolve(retry: [max: -1, backoff_ms: 0])

    assert {:error, %{kind: :bad_opts, message: "headers must be a map or keyword list"}} =
             Options.resolve(headers: "x-trace-id")

    assert {:error, %{kind: :bad_opts, message: "req_options must be a keyword list or map"}} =
             Options.resolve(req_options: :bad)

    assert Options.sanitize_req_options(retry: true, max_retries: 5, pool_timeout: 20) ==
             [pool_timeout: 20]

    assert Options.sanitize_req_options(:bad) == []
  end

  test "sql helpers validate identifiers, rids, and content maps" do
    assert {:ok, "Customer"} = Sql.validate_identifier(:Customer)
    assert {:error, %{kind: :invalid_identifier}} = Sql.validate_identifier("bad-name")
    assert {:ok, "Customer[external_id]"} = Sql.validate_index_name("Customer[external_id]")
    assert {:error, %{kind: :invalid_identifier}} = Sql.validate_index_name("Customer;drop")

    assert {:ok, "#12:0"} = Sql.validate_rid("#12:0")
    assert {:error, %{kind: :bad_opts}} = Sql.validate_rid("12:0")

    assert {:ok, %{"name" => "Alice", "active" => true}} =
             Sql.normalize_map(%{name: "Alice", active: true})

    assert {:error, %{kind: :bad_opts, message: "expected a map"}} =
             Sql.normalize_map(name: "Alice")

    attrs = %{"@rid" => "#12:0", "@type" => "Customer", "name" => "Alice", "@cat" => "d"}

    assert Sql.content_from_insert_attrs(attrs, %{tenant: "ankara", scope: "crm"}) ==
             %{"name" => "Alice", "tenant" => "ankara", "scope" => "crm"}

    assert Sql.drop_system_and_boundary_keys(%{
             "@rid" => "#12:0",
             "@type" => "Customer",
             "@cat" => "d",
             "@in" => "#13:0",
             "@out" => "#14:0",
             "tenant" => "ankara",
             "scope" => "crm",
             "name" => "Alice"
           }) == %{"name" => "Alice"}

    assert Sql.json_map(%{"name" => "Alice"}) == ~s({"name":"Alice"})
  end

  test "sql helpers enforce boundaries and build clauses" do
    opts = %{tenant: "ankara", scope: "crm", type: "Customer"}

    assert Sql.stamp_boundaries(%{"name" => "Alice"}, opts) ==
             %{"name" => "Alice", "tenant" => "ankara", "scope" => "crm"}

    assert {:ok, "Customer"} = Sql.type_from_attrs(%{"@type" => "Customer"}, %{type: nil})
    assert {:ok, "Customer"} = Sql.type_from_attrs(%{}, %{type: "Customer"})

    assert {:error, %{kind: :bad_opts}} =
             Sql.type_from_attrs(%{"@type" => "Person"}, %{type: "Customer"})

    assert {:error, %{kind: :type_required}} = Sql.type_from_attrs(%{}, %{type: nil})

    assert {:ok, "nickname"} = Sql.reject_protected_property(:nickname)
    assert {:error, %{kind: :bad_opts}} = Sql.reject_protected_property("tenant")

    assert {:ok, %{"name" => "Alice"}} = Sql.reject_protected_attrs(%{"name" => "Alice"})
    assert {:error, %{kind: :bad_opts}} = Sql.reject_protected_attrs(%{"tenant" => "ankara"})

    assert {:ok, {where_clause, params}} = Sql.build_filter_clause(%{external_id: "cust-1"}, opts)
    assert where_clause =~ "external_id = :"
    assert where_clause =~ "tenant = :"
    assert where_clause =~ "scope = :"
    assert MapSet.new(Map.values(params)) == MapSet.new(["cust-1", "ankara", "crm"])

    assert {:error, %{kind: :bad_opts, message: "filters cannot be empty"}} =
             Sql.build_filter_clause(%{}, %{tenant: nil, scope: nil})

    assert {:error, %{kind: :invalid_identifier}} =
             Sql.build_filter_clause(%{"@rid" => "#12:0"}, opts)

    assert {:ok, {set_clause, set_params}} =
             Sql.build_assignment_clause(%{name: "Alice", city: "Ankara"}, "u")

    assert set_clause =~ "name = :"
    assert set_clause =~ "city = :"
    assert MapSet.new(Map.values(set_params)) == MapSet.new(["Alice", "Ankara"])

    assert {:error, %{kind: :bad_opts, message: "attributes cannot be empty"}} =
             Sql.build_assignment_clause(%{})

    assert Sql.matches_boundary?(%{"tenant" => "ankara", "scope" => "crm"}, opts)
    refute Sql.matches_boundary?(%{"tenant" => "izmir", "scope" => "crm"}, opts)
    assert Sql.matches_boundary?(%{"name" => "Alice"}, %{tenant: nil, scope: nil})
    refute Sql.matches_boundary?(:bad, opts)
  end

  test "http and wrapper validations fail before network when inputs are bad" do
    assert {:error, %{kind: :bad_opts, details: %{missing: missing}}} =
             Http.server_info(user: "root", pwd: "playwithdata")

    assert :url in missing

    assert {:error, %{kind: :database_required}} =
             Http.query_raw("select 1", %{},
               url: "http://localhost:2480",
               user: "root",
               pwd: "playwithdata"
             )

    assert {:error, %{kind: :bad_opts, message: "retry is not allowed for write helpers"}} =
             Http.command_raw(
               "delete from Customer",
               %{},
               url: "http://localhost:2480",
               user: "root",
               pwd: "playwithdata",
               db: "demo",
               retry: [max: 1, backoff_ms: 0]
             )

    assert {:error, %{kind: :bad_opts, message: "retry is not allowed for write helpers"}} =
             Http.server_command("create database demo",
               url: "http://localhost:2480",
               user: "root",
               pwd: "playwithdata",
               retry: [max: 1, backoff_ms: 0]
             )

    assert Http.unwrap_result(%{"result" => [1, 2]}) == [1, 2]
    assert Http.unwrap_result(%{"ok" => true}) == %{"ok" => true}

    assert {:error, %{kind: :bad_opts, message: "limit must be a positive integer"}} =
             Query.page("select 1", %{}, limit: 0)

    assert {:error,
            %{kind: :bad_opts, message: "limit must be positive and offset must be non-negative"}} =
             Query.stream_pages("select 1", %{}, offset: -1)

    assert {:error,
            %{kind: :bad_opts, message: "chunk_size is not supported on raw command helpers"}} =
             Command.sql("select 1", %{}, %{chunk_size: 100})

    assert {:error, %{kind: :invalid_identifier}} = Database.create("bad-name")
    assert {:error, %{kind: :invalid_identifier}} = Database.drop("bad-name")
    assert {:error, %{kind: :invalid_identifier}} = Database.exists?("bad-name")

    assert {:error, %{kind: :invalid_identifier}} = Schema.create_document_type("bad-name")

    assert {:error, %{kind: :invalid_identifier}} =
             Schema.create_property("Customer", "bad-name", :string)

    assert {:error, %{kind: :invalid_identifier}} = Schema.create_index("Customer", ["bad-name"])
    assert {:error, %{kind: :invalid_identifier}} = Schema.create_vertex_type("bad-name")
    assert {:error, %{kind: :invalid_identifier}} = Schema.create_edge_type("bad-name")
    assert {:error, %{kind: :invalid_identifier}} = Schema.drop_index("bad;name")
    assert {:error, %{kind: :invalid_identifier}} = Schema.drop_bucket("bad-name")

    assert {:error, %{kind: :invalid_identifier}} =
             Vertex.create("bad-name", %{}, fake_connection_opts())

    assert {:error, %{kind: :bad_opts}} =
             Edge.create("Knows", "bad", "#13:0", %{}, fake_connection_opts())
  end

  test "record helper validations fail before network when data is invalid" do
    opts = fake_connection_opts()

    assert {:error, %{kind: :bad_opts, message: "chunk_size is not supported"}} =
             Record.persist(%{"@type" => "Customer"}, opts ++ [chunk_size: 10])

    assert {:error, %{kind: :bad_opts, message: "chunk_size is not supported"}} =
             Record.persist_multi([], opts ++ [chunk_size: 10])

    assert {:error, %{kind: :bad_opts}} = Record.update_property("#12:0", :tenant, "izmir", opts)
    assert {:error, %{kind: :bad_opts}} = Record.merge("#12:0", %{"tenant" => "ankara"}, opts)
    assert {:error, %{kind: :bad_opts}} = Record.replace("#12:0", %{"scope" => "crm"}, opts)

    assert {:error, %{kind: :invalid_identifier}} =
             Record.get(%{name: "Alice"}, opts ++ [type: "bad-name"])

    assert {:error, %{kind: :bad_opts, message: "where cannot be empty"}} =
             Record.upsert("Customer", %{name: "Alice"}, opts ++ [where: %{}])
  end

  test "record and edge helper extractors work on maps and non-maps" do
    record = %{"@rid" => "#12:0", "@type" => "Customer", "@cat" => "d"}
    edge = %{"@out" => "#12:0", "@in" => "#13:0"}

    assert Record.rid(record) == "#12:0"
    assert Record.type(record) == "Customer"
    assert Record.category(record) == "d"
    assert Record.rid(:bad) == nil
    assert Record.type(:bad) == nil
    assert Record.category(:bad) == nil

    assert Edge.out_rid(edge) == "#12:0"
    assert Edge.in_rid(edge) == "#13:0"
    assert Edge.out_rid(:bad) == nil
    assert Edge.in_rid(:bad) == nil
  end

  defp clear_arex_env do
    Enum.each(Application.get_all_env(:arex), fn {key, _value} ->
      Application.delete_env(:arex, key)
    end)
  end

  defp fake_connection_opts do
    [url: "http://localhost:2480", user: "root", pwd: "playwithdata", db: "demo"]
  end
end
