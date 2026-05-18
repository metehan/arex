# Getting Started

This guide takes you from a running ArcadeDB server to your first successful reads and writes with Arex.

Arex is intentionally small. You do not create a public client struct or open a session object in normal usage. Instead, you call module functions and pass options when you need to override defaults.

## Prerequisites

You need:

- an ArcadeDB server that is reachable over HTTP
- credentials for that server
- a target database, or permission to create one

If you want a predictable local environment, the Docker command in [README.md](../README.md) starts ArcadeDB with the `Imported` sample database.

## Install The Library

Add Arex to your dependency list:

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

## Configure Connection Defaults

Arex resolves connection settings in this order:

1. per-call options
2. application config
3. environment variables for `url`, `user`, `pwd`, and `db`

`language` is resolved from call options or application config and otherwise defaults to `"sql"`.

Example `runtime.exs`:

```elixir
import Config

config :arex,
  url: System.fetch_env!("ARCADEDB_URL"),
  user: System.fetch_env!("ARCADEDB_USER"),
  pwd: System.fetch_env!("ARCADEDB_PASSWORD"),
  db: System.fetch_env!("ARCADEDB_DATABASE"),
  language: "sql"
```

Environment fallback names:

- `AREX_URL`
- `AREX_USER`
- `AREX_PWD`
- `AREX_DB`

## Verify Connectivity

Before writing application code, confirm that Arex can reach the server:

```elixir
{:ok, :pong} = Arex.ping()
{:ok, info} = Arex.server_info()
{:ok, dbs} = Arex.Database.list()
```

If you need to target a specific server without changing app config, pass connection options directly:

```elixir
Arex.ping(
  url: "http://localhost:2480",
  user: "root",
  pwd: "playwithdata"
)
```

## Read Existing Data

When a database already contains data, `Arex.Query` is the fastest way to get started:

```elixir
{:ok, rows} =
  Arex.Query.sql(
    "select from Beer where id = :id",
    %{"id" => 1},
    db: "Imported"
  )
```

Helpful read helpers:

- `Arex.Query.sql/3` executes SQL and returns all rows.
- `Arex.Query.first/3` returns the first row or `nil`.
- `Arex.Query.one/3` returns exactly one row or fails with `:multiple_results`.
- `Arex.Query.page/3` returns a page map with `entries`, `limit`, `offset`, `count`, and `has_more?`.
- `Arex.Query.stream_pages/3` yields pages as a stream for larger result sets.

## Create Your Own Database And Type

If you are starting from an empty environment, provision a database and type first:

```elixir
{:ok, :created} = Arex.Database.create("crm")
{:ok, _} = Arex.Schema.create_document_type("Customer", db: "crm")
{:ok, _} = Arex.Schema.create_property("Customer", "external_id", :string, db: "crm")
{:ok, _} = Arex.Schema.create_index("Customer", ["external_id"], db: "crm", unique: true)
```

That gives you a concrete record type for the higher-level CRUD helpers.

## Write Your First Record

`Arex.Record.persist/2` inserts when no `@rid` is present and updates when `@rid` is present.

```elixir
{:ok, customer} =
  Arex.Record.persist(
    %{external_id: "cust-1", name: "Ada Lovelace"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )
```

Important rules:

- `type` is required for inserts unless the input map already contains `@type`
- `scope` always requires `tenant`
- insert-like helpers stamp `tenant` and `scope` into the record when present
- reads using the same boundary only see records that match that boundary

Fetch the record again by RID:

```elixir
{:ok, same_customer} =
  Arex.Record.fetch(
    customer["@rid"],
    db: "crm",
    tenant: "ankara",
    scope: "sales"
  )
```

## Understand The Boundary Model

Arex uses three layers of isolation:

1. `db` picks the ArcadeDB database.
2. `tenant` scopes records inside that database.
3. `scope` narrows records inside the tenant.

Boundary-aware helpers use these rules consistently:

- writes stamp `tenant` and `scope` into stored content
- reads automatically filter by those fields when provided
- attempting to cross boundaries yields `:not_found`
- helper APIs reject direct mutation of protected boundary keys

This is one of Arex's main advantages over scattering raw SQL through application code.

## Pick The Right Module

| Module          | Start here when you need                 |
| --------------- | ---------------------------------------- |
| `Arex`          | connectivity checks and server metadata  |
| `Arex.Query`    | raw reads and paging                     |
| `Arex.Command`  | raw write commands or SQLScript          |
| `Arex.Record`   | document-style CRUD                      |
| `Arex.Schema`   | types, properties, indexes, and buckets  |
| `Arex.Database` | create, drop, list, or inspect databases |
| `Arex.Vertex`   | graph vertex creation and traversal      |
| `Arex.Edge`     | graph edge creation and lookup           |

## What To Read Next

- [Records and Queries](records_and_queries.md) for the high-level CRUD API and paging semantics.
- [Graph and Schema](graph_and_schema.md) for schema changes, graph helpers, and provisioning workflows.
- [Runtime Behavior](runtime_behavior.md) for retries, timeouts, and normalized error handling.