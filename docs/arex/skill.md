---
name: arex
description: 'Use when working with Arex, the ArcadeDB-native Elixir client, including tenant/scope aware records, schema helpers, graph helpers, raw query/command usage, and production rollout guidance.'
---

# Arex Skill Guide

Use this guide when an AI agent needs to work with Arex in application code.

## Purpose

Arex is an ArcadeDB-native Elixir client that wraps the HTTP API with higher-level helpers for:

- querying and raw commands
- key/value and time-series access
- vector search and embedding index helpers
- tenant and scope aware records
- schema and database operations
- graph traversal and edge creation

## Guide Map

- `../getting_started.md` for setup, configuration, and first-use examples.
- `../records_and_queries.md` for CRUD helpers, paging, batching, and upserts.
- `../graph_and_schema.md` for provisioning, schema changes, and graph usage.
- `../runtime_behavior.md` for retries, timeouts, normalized errors, and observability.

## Configuration Rules

- Connection values are resolved from call opts, then app config, then env for `url`, `user`, `pwd`, and `db`.
- `language` is not env-backed. It comes from call opts or app config and otherwise defaults to `"sql"`.
- `receive_timeout` defaults to 60 seconds when omitted.
- `retry` is disabled by default and is only supported on read helpers.
- `scope` requires `tenant`.

## Core Modules

- `Arex`: ping and server info.
- `Arex.Query`: read-oriented helpers such as `sql/3`, `first/3`, `one/3`, `page/3`, and `stream_pages/3`.
- `Arex.Command`: raw command helpers such as `sql/3` and `sqlscript/3`.
- `Arex.KV`: Redis-language key/value and persistent hash helpers over HTTP.
- `Arex.TimeSeries`: TimeSeries DDL, SQL access, line protocol, JSON query, PromQL, and Grafana endpoint helpers.
- `Arex.Vector`: vector property setup, dense and sparse index creation, nearest-neighbor queries, and hybrid fusion helpers.
- `Arex.Record`: CRUD helpers with boundary stamping and filtering.
- `Arex.Schema` and `Arex.Database`: administrative helpers.
- `Arex.Vertex` and `Arex.Edge`: graph helpers built on top of `Arex.Record`, `Arex.Query`, and `Arex.Command`.

## Usage Conventions

- Prefer `Arex.Query.sql/3` and `Arex.Command.sql/3` unless you explicitly need a non-SQL language.
- Prefer `Arex.KV` over hand-built Redis command strings for common key/value flows.
- Prefer `Arex.TimeSeries` for TimeSeries DDL and dedicated endpoint usage instead of hand-building `/ts` paths.
- Prefer `Arex.Vector` for `LSM_VECTOR`, `LSM_SPARSE_VECTOR`, and `vector.*` SQL wrappers instead of hand-building metadata JSON.
- Use `Arex.Record` for document-style reads and writes instead of building raw statements for common CRUD paths.
- Use `tenant` and `scope` consistently on both reads and writes when the application model is boundary-aware.
- Prefer wrapped `Arex.KV` helpers over `run/2` when you want tenant/scope key isolation.
- Prefer wrapped `Arex.TimeSeries` insert and query helpers over raw SQL or raw line protocol when you want tenant/scope tags enforced automatically.
- Do not try to mutate `tenant`, `scope`, `@rid`, `@type`, `@in`, or `@out` through helper APIs that explicitly protect those fields.
- Use `persist_multi/2` when you need one transaction across many record changes.

## Important Behaviors

- `persist_multi/2` runs inside one SQLScript transaction.
- `fetch_multi/2` returns `nil` entries for missing or out-of-boundary records.
- `get_one/2` returns `{:ok, nil}` for no rows and `{:error, %{kind: :multiple_results}}` for ambiguous matches.
- `upsert/3` requires a non-empty `where:` clause and fails when more than one row matches.
- Query pagination uses `skip` and `limit` under the hood because ArcadeDB rejected direct `offset` SQL in live testing.
- Non-unique index creation requires the explicit `notunique` keyword in ArcadeDB SQL.
- Dropping bracketed index names such as `Customer[field]` requires backtick quoting.
- SQLScript scalar responses come back through the HTTP API as result rows such as `%{"value" => 5}`.
- Write helpers reject `retry:` and Arex strips retry-related keys from `req_options`.
- `Arex.Http.request/4` is the low-level escape hatch for authenticated non-standard ArcadeDB endpoints.
- Wrapped `Arex.KV` key helpers namespace keys by active `tenant` and `scope`, but `run/2` and `batch/2` are still raw.
- Wrapped `Arex.TimeSeries` writes stamp `tenant` and `scope` tags, and wrapped SQL/latest reads apply those boundaries when present.

## Operational Rules

- Arex does not emit its own Telemetry events or logs; instrument call sites at the application boundary.
- Log normalized error maps instead of raw payload guesses, but redact credentials and auth headers.
- For local verification or CI, start `arcadedata/arcadedb` with an empty `test_db` database provisioned as `test_db[test_user:test_password]`; integration tests must run without relying on sample imports or root-only database creation.

## Example

```elixir
{:ok, customer} =
  Arex.Record.persist(
    %{name: "Ada"},
    db: "crm",
    type: "Customer",
    tenant: "ankara",
    scope: "sales"
  )

{:ok, page} =
  Arex.Query.page(
    "select from Customer order by @rid",
    %{},
    db: "crm",
    tenant: "ankara",
    scope: "sales",
    limit: 50
  )
```

## When To Drop Lower

- Use `Arex.Http` only when you need raw request/response control.
- Use `Arex.Sql` and `Arex.Options` only for internal extensions or library work, not typical application code.
