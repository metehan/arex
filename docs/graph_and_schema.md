# Graph And Schema

This guide covers the operational and graph-oriented parts of Arex: database provisioning, schema changes, vertex and edge helpers, and the boundary rules that apply to graph workflows.

## Database Helpers

`Arex.Database` works at the database level rather than inside a specific record type.

| Helper                  | Behavior                                                            |
| ----------------------- | ------------------------------------------------------------------- |
| `list/1`                | lists database names visible to the configured credentials          |
| `create/2`              | creates a database and returns `{:ok, :created}`                    |
| `drop/2`                | drops a database and returns `{:ok, :missing}` if it does not exist |
| `exists?/2`             | returns whether a database exists                                   |
| `stats/1` and `stats/2` | returns a lightweight summary built from `schema:types`             |

Example:

```elixir
{:ok, :created} = Arex.Database.create("social")
{:ok, true} = Arex.Database.exists?("social")
{:ok, stats} = Arex.Database.stats("social", [])
```

## Schema Helpers

`Arex.Schema` keeps the API close to ArcadeDB's schema commands while normalizing some common missing-resource cases.

### Types

Use these helpers to create or inspect document, vertex, and edge types:

- `types/1`
- `type/2`
- `create_document_type/2`
- `create_vertex_type/2`
- `create_edge_type/2`
- `drop_type/2`

Example:

```elixir
{:ok, _} = Arex.Schema.create_document_type("Customer", db: "crm")
{:ok, _} = Arex.Schema.create_vertex_type("Person", db: "social")
{:ok, _} = Arex.Schema.create_edge_type("Knows", db: "social")
```

`drop_type/2` returns `{:ok, :missing}` when the type is not present.

### Properties

Properties are managed per type:

- `properties/2`
- `create_property/4`
- `drop_property/3`

Example:

```elixir
{:ok, _} = Arex.Schema.create_property("Customer", "external_id", :string, db: "crm")
{:ok, props} = Arex.Schema.properties("Customer", db: "crm")
```

`drop_property/3` also returns `{:ok, :missing}` when the property does not exist.

### Indexes

Index helpers are available globally or per type:

- `indexes/1`
- `indexes/2`
- `create_index/3`
- `drop_index/2`

Example:

```elixir
{:ok, _} = Arex.Schema.create_index("Customer", ["external_id"], db: "crm", unique: true)
{:ok, _} = Arex.Schema.create_index("Customer", ["status"], db: "crm")
```

Important ArcadeDB behavior that Arex handles explicitly:

- non-unique indexes must be created with the `notunique` keyword
- bracketed index names such as `Customer[external_id]` must be dropped with backtick quoting

`drop_index/2` returns `{:ok, :missing}` when the index cannot be found.

### Buckets

Bucket helpers are available when you need them:

- `buckets/1`
- `bucket/2`
- `create_bucket/2`
- `drop_bucket/2`

`drop_bucket/2` returns `{:ok, :missing}` when the bucket is absent.

## Bootstrapping A Graph Database

The following example shows a small but complete setup flow:

```elixir
{:ok, :created} = Arex.Database.create("social")
{:ok, _} = Arex.Schema.create_vertex_type("Person", db: "social")
{:ok, _} = Arex.Schema.create_property("Person", "external_id", :string, db: "social")
{:ok, _} = Arex.Schema.create_index("Person", ["external_id"], db: "social", unique: true)
{:ok, _} = Arex.Schema.create_edge_type("Knows", db: "social")
```

Once the schema exists, the graph helpers become straightforward.

## Vertex Helpers

`Arex.Vertex` builds on the record and query layers.

| Helper       | Behavior                                             |
| ------------ | ---------------------------------------------------- |
| `create/3`   | creates a vertex and stamps active boundaries        |
| `fetch/2`    | fetches a vertex by RID                              |
| `delete/2`   | deletes a vertex by RID                              |
| `merge/3`    | merges attributes into a vertex                      |
| `replace/3`  | replaces a vertex content payload                    |
| `upsert/3`   | uses the same upsert rules as `Arex.Record.upsert/3` |
| `out/3`      | returns outgoing neighbor vertices                   |
| `incoming/3` | returns incoming neighbor vertices                   |
| `both/3`     | returns incoming and outgoing neighbor vertices      |

Example:

```elixir
{:ok, alice} =
  Arex.Vertex.create(
    "Person",
    %{external_id: "p-1", name: "Alice"},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )
```

Traversal calls can optionally limit by edge type:

```elixir
{:ok, neighbors} =
  Arex.Vertex.out(alice["@rid"], "Knows", db: "social", tenant: "ankara", scope: "graph")
```

## Edge Helpers

`Arex.Edge` is the companion module for graph relationships.

| Helper      | Behavior                                                        |
| ----------- | --------------------------------------------------------------- |
| `create/5`  | creates an edge between two existing vertices                   |
| `fetch/2`   | fetches an edge by RID                                          |
| `delete/2`  | deletes an edge by RID                                          |
| `between/4` | finds edges from one vertex to another, optionally by edge type |
| `out_rid/1` | extracts the source RID from an edge record                     |
| `in_rid/1`  | extracts the destination RID from an edge record                |

Example:

```elixir
{:ok, bob} =
  Arex.Vertex.create(
    "Person",
    %{external_id: "p-2", name: "Bob"},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )

{:ok, edge} =
  Arex.Edge.create(
    "Knows",
    alice["@rid"],
    bob["@rid"],
    %{},
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )

{:ok, edges} =
  Arex.Edge.between(
    alice["@rid"],
    bob["@rid"],
    "Knows",
    db: "social",
    tenant: "ankara",
    scope: "graph"
  )
```

## Boundary-Aware Graph Behavior

The graph helpers use the same tenant and scope rules as the record helpers:

- vertex and edge creation stamp active boundaries into the stored record
- the source and destination records must already be visible within the active boundary
- traversal results are filtered to the active boundary before they are returned
- cross-boundary access behaves as `:not_found` or an empty result, depending on the helper

This matters when multiple tenants can have similarly shaped graph data inside the same database.

## Related Guides

- [Getting Started](getting_started.md)
- [Records and Queries](records_and_queries.md)
- [Runtime Behavior](runtime_behavior.md)