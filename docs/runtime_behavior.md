# Runtime Behavior

This guide documents the parts of Arex that affect production behavior: option resolution, retries, timeouts, normalized errors, observability, and ArcadeDB-specific quirks.

## Option Resolution

Arex resolves options in a predictable order:

1. per-call options
2. application config for `:arex`
3. environment variables for `url`, `user`, `pwd`, and `db`

`language` does not use environment fallback. It comes from call options or application config and otherwise defaults to `"sql"`.

This means you can keep stable connection defaults in config while overriding them per call for tests, admin jobs, or multi-database workloads.

## Important Call Options

| Option                | Meaning                                                         |
| --------------------- | --------------------------------------------------------------- |
| `db`                  | target database for the call                                    |
| `type`                | type name for type-aware record helpers                         |
| `tenant`              | tenant boundary                                                 |
| `scope`               | scope boundary inside a tenant                                  |
| `language`            | query or command language, defaulting to `sql`                  |
| `receive_timeout`     | HTTP receive timeout in milliseconds                            |
| `retry`               | read retry policy such as `[max: 3, backoff_ms: 200]`           |
| `headers`             | extra request headers, merged without overriding auth           |
| `req_options`         | sanitized Req options merged into the request                   |

Validation rules worth remembering:

- `scope` requires `tenant`
- `receive_timeout` must be a positive integer when present
- `retry` must be `false` or a keyword list with non-negative `max` and `backoff_ms`
- `headers` must be a map or keyword list
- `req_options` must be a map or keyword list

## Timeouts And Retries

Arex makes retry behavior explicit instead of hiding it behind transport defaults.

- `receive_timeout` defaults to `60_000` milliseconds when omitted
- read helpers can opt into retry with `retry: [max: n, backoff_ms: ms]`
- write helpers reject `retry:` with `{:error, %{kind: :bad_opts, ...}}`
- `req_options` retry-related keys are stripped so callers cannot override helper retry policy indirectly

Example read tuning:

```elixir
Arex.Query.sql(
  "select from Customer where external_id = :external_id",
  %{"external_id" => "cust-1"},
  db: "crm",
  receive_timeout: 15_000,
  retry: [max: 2, backoff_ms: 100]
)
```

## Return Contract

Every public helper returns one of two shapes:

- `{:ok, value}`
- `{:error, error_map}`

Arex uses normalized error maps so application code can branch on `error.kind` instead of parsing raw HTTP bodies.

Example:

```elixir
{:error,
 %{
   kind: :arcadedb,
   message: "Database 'crm' is not available",
   status: 500,
   arcade_code: nil,
   details: nil,
   body: %{},
   request: %{method: :post, path: "/api/v1/query/crm"}
 }}
```

Common `kind` values:

- `:arcadedb`
- `:database_required`
- `:type_required`
- `:scope_without_tenant`
- `:invalid_identifier`
- `:multiple_results`
- `:bad_opts`
- `:not_found`

## Boundary Behavior

Boundary rules are runtime behavior, not just convenience syntax.

- insert-like helpers stamp `tenant` and `scope` into stored content
- boundary-aware reads filter by `tenant` and `scope`
- `Arex.KV` applies boundary namespaces on wrapped key helpers such as `get/2`, `set/3`, and `exists?/2`
- `Arex.TimeSeries` stamps `tenant` and `scope` into boundary-aware writes and filters wrapped SQL/latest reads through those tags
- RID-based reads and writes still enforce boundary visibility
- crossing a boundary is treated as `:not_found`

That behavior is what lets Arex provide safe multi-tenant helpers without exposing cross-boundary existence through helper APIs.

Raw escape hatches stay raw:

- `Arex.KV.run/2` and `Arex.KV.batch/2` do not rewrite arbitrary Redis command strings
- hand-written TimeSeries SQL, PromQL, JSON payloads, or remote-read/write payloads are still caller-controlled unless a wrapper explicitly adds boundary tags or filters

## Transport Details

Arex builds on Req and ArcadeDB's HTTP API.

Important details:

- caller headers are merged on top of Arex defaults, except `authorization`, which is protected
- `req_options` are merged after sanitization
- low-level helpers use `/api/v1/query/:db`, `/api/v1/command/:db`, and `/api/v1/server`
- `Arex.Query.sql/3` and `Arex.Command.sql/3` always force `language: "sql"`
- `Arex.Command.sqlscript/3` forces `language: "sqlscript"`

## Observability And Logging

Arex does not emit Telemetry events or structured logs on its own.

Recommended practice:

- wrap Arex calls in your own tracing, logging, or telemetry spans
- attach `error.kind`, `error.status`, and `error.request` to logs or spans
- redact passwords, auth headers, and other secrets before logging inputs or failures
- keep any Req or Finch instrumentation at your application boundary rather than expecting Arex-specific events

## ArcadeDB-Specific Behavior

Arex documents the ArcadeDB behavior it relies on explicitly:

- pagination uses `skip` and `limit`, not raw `offset`, in generated SQL
- non-unique index creation requires explicit `notunique`
- dropping bracketed index names requires backtick quoting
- SQLScript scalar results come back as rows such as `%{"value" => 5}`

These are not theoretical notes. They are behaviors observed against the live HTTP API and encoded into helper behavior.
