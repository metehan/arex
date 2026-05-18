# Arex

Arex is an ArcadeDB-native Elixir client for applications that want a direct, idiomatic API over ArcadeDB's HTTP interface.

It is built around a small set of promises:

- plain Elixir maps in and out
- one-off function calls instead of a public client struct
- tenant and scope boundaries enforced by the high-level helpers
- normalized `{:ok, value}` and `{:error, error_map}` return shapes
- practical coverage for document, graph, schema, and database workflows

## Highlights

- `Arex.Query` and `Arex.Command` wrap raw query and command execution.
- `Arex.Record` provides document-style CRUD with tenant and scope awareness.
- `Arex.Vertex` and `Arex.Edge` cover graph creation and traversal.
- `Arex.Schema` and `Arex.Database` handle types, properties, indexes, buckets, and databases.
- `Arex.Error` exposes stable `error.kind` values for branching in application code.

## Documentation Map

- [Getting Started](docs/getting_started.md) covers installation, configuration, first reads, and first writes.
- [Records and Queries](docs/records_and_queries.md) explains CRUD helpers, paging, batching, upserts, and when to drop to raw SQL.
- [Graph and Schema](docs/graph_and_schema.md) documents provisioning, schema changes, graph helpers, and traversal patterns.
- [Runtime Behavior](docs/runtime_behavior.md) explains option resolution, retries, timeouts, normalized errors, and observability expectations.
- [Production Readiness](docs/production_readiness.md) is the release and rollout checklist.
- [AI Skill Guide](docs/arex/skill.md) summarizes safe usage rules for automation and agent workflows.

## Installation

Add Arex to your dependencies:

```elixir
defp deps do
  [
    {:arex, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Configuration

Arex resolves connection settings in this order:

1. per-call options
2. application config
3. environment variables for `url`, `user`, `pwd`, and `db`

`language` is intentionally different. It is resolved from call options or application config and otherwise defaults to `"sql"`.

Recommended `runtime.exs` configuration:

```elixir
import Config

config :arex,
  url: System.fetch_env!("ARCADEDB_URL"),
  user: System.fetch_env!("ARCADEDB_USER"),
  pwd: System.fetch_env!("ARCADEDB_PASSWORD"),
  db: System.fetch_env!("ARCADEDB_DATABASE"),
  language: "sql"
```

If you want Arex's built-in environment fallback, export these variables:

- `AREX_URL`
- `AREX_USER`
- `AREX_PWD`
- `AREX_DB`

Common call options:

- `db` selects the ArcadeDB database when you do not want to use the configured default.
- `type` supplies the record type for helpers such as `Arex.Record.get/2`.
- `tenant` and `scope` define the application boundary for boundary-aware helpers.
- `receive_timeout` sets the HTTP receive timeout in milliseconds.
- `retry` enables read retries with a value such as `[max: 3, backoff_ms: 200]`.
- `transaction` and `transaction_timeout` tune write helpers that need transactional behavior.
- `headers` merges extra request headers without allowing callers to override auth headers.
- `req_options` merges sanitized Req options after Arex strips retry settings that would bypass helper policy.

## Quick Start

The following example assumes you have a running ArcadeDB server and want to store tenant-scoped customer records in a `crm` database.

```elixir
alias Arex.{Query, Record, Schema}

# Run this once when bootstrapping an empty database.
{:ok, _} = Schema.create_document_type("Customer", db: "crm")
{:ok, _} = Schema.create_property("Customer", "external_id", :string, db: "crm")
{:ok, _} = Schema.create_index("Customer", ["external_id"], db: "crm", unique: true)

{:ok, customer} =
  Record.persist(
    %{external_id: "cust-1", name: "Ada Lovelace"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )

{:ok, same_customer} =
  Record.fetch(customer["@rid"], db: "crm", tenant: "ankara", scope: "sales")

{:ok, page} =
  Query.page(
    "select from Customer where tenant = :tenant and scope = :scope order by @rid",
    %{"tenant" => "ankara", "scope" => "sales"},
    db: "crm",
    limit: 25
  )
```

## Boundary Model

Arex treats `db`, `tenant`, and `scope` as separate layers of isolation.

- `db` chooses the ArcadeDB database.
- `tenant` scopes records inside a database.
- `scope` refines data inside a tenant and always requires `tenant`.

Boundary rules are consistent across the high-level APIs:

- insert-like helpers stamp `tenant` and `scope` into written content when present
- boundary-aware reads automatically filter by `tenant` and `scope`
- attempts to mutate protected boundary fields through helper APIs are rejected
- cross-boundary access behaves as `:not_found` rather than leaking existence

This gives application code a stable model without repeating the same predicates in every call site.

## Module Guide

| Module          | Use it for                                         |
| --------------- | -------------------------------------------------- |
| `Arex`          | connectivity checks and server metadata            |
| `Arex.Query`    | raw reads, paging, and streaming                   |
| `Arex.Command`  | raw write commands and SQLScript execution         |
| `Arex.Record`   | document-style CRUD helpers                        |
| `Arex.Schema`   | types, properties, indexes, and buckets            |
| `Arex.Database` | database creation, existence checks, and summaries |
| `Arex.Vertex`   | vertex creation, updates, and traversal            |
| `Arex.Edge`     | edge creation and lookups between vertices         |
| `Arex.Error`    | normalized error maps returned by all helpers      |

## Common Workflows

### Records And Queries

Use `Arex.Record` when you want the library to handle type resolution, boundary stamping, and common CRUD patterns for you.

```elixir
{:ok, customer} =
  Arex.Record.upsert(
    "Customer",
    %{name: "Ada Lovelace", status: "active"},
    db: "crm",
    where: %{external_id: "cust-1"},
    tenant: "ankara",
    scope: "sales"
  )

{:ok, exists?} =
  Arex.Record.is_there?(
    %{external_id: "cust-1"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )

{:ok, first_row} =
  Arex.Query.first(
    "select from Customer where tenant = :tenant and scope = :scope order by @rid",
    %{"tenant" => "ankara", "scope" => "sales"},
    db: "crm"
  )
```

Use `Arex.Query` or `Arex.Command` when you need explicit control over the statement you send to ArcadeDB.

### Graph Workflows

Use `Arex.Vertex` and `Arex.Edge` when your application works with graph types but you still want the same boundary semantics as document helpers.

```elixir
{:ok, alice} =
  Arex.Vertex.create(
    "Person",
    %{name: "Alice"},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )

{:ok, bob} =
  Arex.Vertex.create(
    "Person",
    %{name: "Bob"},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )

{:ok, _edge} =
  Arex.Edge.create(
    "Knows",
    alice["@rid"],
    bob["@rid"],
    %{},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )

{:ok, neighbors} =
  Arex.Vertex.out(alice["@rid"], "Knows", db: "social", tenant: "ankara", scope: "graph")
```

### Schema And Database Administration

Use `Arex.Database` and `Arex.Schema` for setup, migrations, test provisioning, and operational inspection.

```elixir
{:ok, :created} = Arex.Database.create("analytics")
{:ok, _} = Arex.Schema.create_document_type("Event", db: "analytics")
{:ok, _} = Arex.Schema.create_property("Event", "kind", :string, db: "analytics")
{:ok, _} = Arex.Schema.create_index("Event", ["kind"], db: "analytics")
{:ok, stats} = Arex.Database.stats(db: "analytics")
```

For a deeper walkthrough, see [Graph and Schema](docs/graph_and_schema.md).

## Return Values And Errors

All public helpers return one of two shapes:

- `{:ok, value}`
- `{:error, error_map}`

Example error:

```elixir
{:error,
 %{
   kind: :not_found,
   message: "record not found",
   status: nil,
   arcade_code: nil,
   details: nil,
   body: %{},
   request: %{method: :post, path: "/api/v1/query/mydb"}
 }}
```

Important contract notes:

- `persist_multi/2` runs inside one SQLScript transaction and is atomic.
- `fetch_multi/2` returns `nil` entries for missing or out-of-boundary records.
- `get_one/2` returns `{:ok, nil}` for no rows and `{:error, %{kind: :multiple_results}}` for ambiguous matches.
- `upsert/3` requires a non-empty `where:` clause and fails when more than one row matches.
- `Arex.Query.page/3` accepts `offset:` at the Elixir API boundary, but internally emits ArcadeDB `skip` and `limit` syntax.

## Runtime Behavior

Arex exposes a small, explicit set of transport controls:

- `receive_timeout` defaults to `60_000` milliseconds when omitted.
- `retry` is disabled by default and is supported only on read helpers.
- write helpers reject `retry:` instead of silently retrying writes.
- `req_options` are sanitized before merge so callers cannot override helper retry policy.
- `headers` can add request headers but cannot replace Arex's auth handling.

If you need the lower-level details, see [Runtime Behavior](docs/runtime_behavior.md).

## ArcadeDB Compatibility Notes

Arex documents the ArcadeDB quirks it depends on rather than hiding them:

- generated pagination uses `skip` and `limit` because direct `offset` SQL parsing failed in live ArcadeDB testing
- non-unique index creation must emit ArcadeDB's explicit `notunique` keyword
- dropping bracketed index names such as `Customer[field]` requires backtick quoting around the raw SQL index name
- SQLScript scalar returns arrive through the HTTP API as rows such as `%{"value" => 5}` rather than bare integers

## Observability

Arex does not emit its own Telemetry events or logs. Instrumentation belongs at the application boundary:

- wrap Arex calls in your own logging, tracing, or telemetry spans
- use `error.request`, `error.status`, and `error.details` when enriching logs
- redact passwords, auth headers, and other secrets before logging inputs or failures

## Local Development

The integration suite expects a live ArcadeDB server with the `Imported` sample database available. The official Docker image can provision that in one command:

```bash
docker run --rm -p 2480:2480 -p 2424:2424 \
  -e 'JAVA_OPTS=-Darcadedb.server.rootPassword=playwithdata -Darcadedb.server.defaultDatabases=Imported[root]{import:https://github.com/ArcadeData/arcadedb-datasets/raw/main/orientdb/OpenBeer.gz}' \
  arcadedata/arcadedb:latest
```

With the server running, export the values expected by local docs generation and the integration tests:

```bash
export AREX_URL=http://localhost:2480
export AREX_USER=root
export AREX_PWD=playwithdata
export AREX_DB=Imported
```

Typical maintenance flow:

```bash
mix format
mix docs
mix test --cover
```

`mix docs` writes the generated site to `doc/`.

## Additional Reading

- [Getting Started](docs/getting_started.md)
- [Records and Queries](docs/records_and_queries.md)
- [Graph and Schema](docs/graph_and_schema.md)
- [Runtime Behavior](docs/runtime_behavior.md)
- [Production Readiness](docs/production_readiness.md)
- [CHANGELOG.md](CHANGELOG.md)