# Records And Queries

This guide covers the core day-to-day API surface in Arex: read helpers, document-style CRUD helpers, boundary behavior, and batching.

## Read Helpers

`Arex.Query` is the direct path when you already know the statement you want ArcadeDB to execute.

| Helper           | Use it when                                                 |
| ---------------- | ----------------------------------------------------------- |
| `run/3`          | you want to use the resolved `language` from opts or config |
| `sql/3`          | you want an explicit SQL query                              |
| `first/3`        | you want the first row or `nil`                             |
| `one/3`          | you expect zero or one row and want ambiguity to fail       |
| `page/3`         | you want one page of results plus paging metadata           |
| `stream_pages/3` | you want to consume multiple pages lazily                   |

Example:

```elixir
{:ok, page} =
  Arex.Query.page(
    "select from Customer where tenant = :tenant and scope = :scope order by @rid",
    %{"tenant" => "ankara", "scope" => "sales"},
    db: "crm",
    limit: 100,
    offset: 0
  )
```

Notes:

- `limit` must be a positive integer.
- `offset` must be a non-negative integer.
- the Elixir API accepts `offset`, but Arex emits ArcadeDB `skip` and `limit` internally because that is what the tested HTTP API accepts reliably.

## Raw Write Helpers

`Arex.Command` is the escape hatch when a write does not fit the higher-level APIs.

| Helper        | Use it when                                                    |
| ------------- | -------------------------------------------------------------- |
| `run/3`       | you want the resolved `language` for a command                 |
| `sql/3`       | you want an explicit SQL command                               |
| `sqlscript/3` | you need multiple command steps or explicit transaction blocks |

Arex normalizes raw command results to `%{count: ..., records: ...}`.

Example:

```elixir
{:ok, %{count: count, records: rows}} =
  Arex.Command.sql(
    "select count(*) as count from Customer where tenant = :tenant and scope = :scope",
    %{"tenant" => "ankara", "scope" => "sales"},
    db: "crm"
  )
```

## Document-Style CRUD Helpers

`Arex.Record` exists so application code does not need to rebuild the same `insert`, `update`, boundary, and cardinality logic over and over.

### Insert Or Update With `persist/2`

`persist/2` chooses its behavior from the presence of `@rid`:

- without `@rid`, it inserts a new record
- with `@rid`, it updates the existing record by RID

Insert example:

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

Update example:

```elixir
{:ok, updated} =
  Arex.Record.persist(
    %{"@rid" => customer["@rid"], "name" => "Ada Byron"},
    db: "crm",
    tenant: "ankara",
    scope: "sales"
  )
```

`persist_new/2` is the clone-like variant. It removes any existing `@rid` and always inserts a new record.

### Fetch By RID

`fetch/2` returns one record and enforces boundary checks when `tenant` or `scope` are active.

```elixir
{:ok, record} =
  Arex.Record.fetch(customer["@rid"], db: "crm", tenant: "ankara", scope: "sales")
```

`fetch_multi/2` is useful when you want positional results back. Missing or out-of-boundary rows come back as `nil` entries instead of failing the whole call.

### Find By Filters

`get/2`, `get_one/2`, and `is_there?/2` are type-aware query helpers.

```elixir
{:ok, matches} =
  Arex.Record.get(
    %{status: "active"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )

{:ok, maybe_customer} =
  Arex.Record.get_one(
    %{external_id: "cust-1"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )
```

Important behavior:

- `type` is required
- filters cannot be empty
- `get_one/2` returns `{:ok, nil}` when nothing matches
- `get_one/2` fails with `:multiple_results` when the filter is ambiguous
- boundary filters are appended automatically when `tenant` or `scope` are present

### Targeted Mutation Helpers

Arex includes convenience helpers for common mutations:

- `update_property/4`
- `push/4`
- `pop/4`
- `switch_on/3`
- `switch_off/3`
- `merge/3`
- `replace/3`

Example:

```elixir
{:ok, updated} =
  Arex.Record.update_property(
    customer["@rid"],
    :city,
    "Ankara",
    db: "crm",
    tenant: "ankara",
    scope: "sales"
  )
```

Protected fields such as `tenant`, `scope`, `@rid`, `@type`, `@in`, and `@out` are rejected when a helper is documented as protecting them.

### Upserts

`upsert/3` is useful when your logical identity is a filter rather than a known RID.

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
```

Rules:

- `where:` is required
- `where:` cannot be empty
- attributes cannot be empty
- the operation fails if more than one row matches the `where:` clause

### Deletes

`vaporize/2` deletes a record map that contains `@rid`.

`vaporize_by_id/2` deletes directly by RID.

Both variants enforce the active boundary before deleting.

## Batch Writes And Atomicity

`persist_multi/2` stores multiple records inside one SQLScript transaction.

```elixir
{:ok, [updated, inserted]} =
  Arex.Record.persist_multi(
    [
      %{"@rid" => existing_rid, "name" => "Updated Name"},
      %{"@type" => "Customer", "external_id" => "cust-2", "name" => "New Customer"}
    ],
    db: "crm",
    tenant: "ankara",
    scope: "sales"
  )
```

If one operation fails, the batch fails as a unit.

## Boundary Semantics

Boundaries are a major part of the record API and they apply consistently:

- inserts stamp `tenant` and `scope` when present
- reads only return rows that match the active boundary
- RID-based helpers still enforce tenant and scope validation after fetch
- a boundary mismatch is reported as `:not_found`
- `scope` cannot be used without `tenant`

This means identical logical records can exist across tenants or scopes without leaking into one another.

## When To Use `Query` Or `Command` Instead

Prefer the high-level record API when you want:

- automatic boundary stamping and filtering
- normalized CRUD behavior
- `where:`-based upserts
- list and boolean convenience helpers

Drop to `Arex.Query` or `Arex.Command` when you need:

- a statement that is easier to express directly in SQL
- schema or traversal logic not covered by the higher-level helpers
- SQLScript control over multi-step writes

## Related Guides

- [Getting Started](getting_started.md)
- [Graph and Schema](graph_and_schema.md)
- [Runtime Behavior](runtime_behavior.md)