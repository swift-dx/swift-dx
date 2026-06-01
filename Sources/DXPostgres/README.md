# DXPostgres

A native, pure-Swift client for PostgreSQL and the servers that speak its wire
protocol (YugabyteDB YSQL, CockroachDB, and managed variants). DXPostgres
implements the PostgreSQL v3 frontend/backend protocol directly over SwiftNIO —
there is no `libpq` dependency and no system library to link.

## Status

What works today:

- Connection and startup handshake with **SCRAM-SHA-256**, **MD5**, and
  **cleartext** authentication, plus **TLS** negotiation (`SSLRequest`).
- A bounded, `Sendable` connection **pool** behind `PostgresClient`; callers
  beyond the connection cap queue (FIFO) for a free connection.
- **Simple queries** (`query("SELECT …")`) and **parameterized queries** over
  the extended protocol (`query("… $1 …", binding: […])`). Parameterized queries
  request results in **binary format**, which is faster to decode and exact for
  floating point, timestamps, UUIDs, and `bytea`; simple queries use text. The
  row decoders handle both.
- **Row streaming** (`queryStream`) yields rows as they arrive over an
  `AsyncThrowingStream` instead of buffering the whole result set, so large scans
  run in bounded memory. The leased connection is returned to the pool when the
  stream finishes and closed if the stream is abandoned early.
- **Type coverage** via `PostgresDecodable`/`PostgresEncodable`: `String`, the
  signed integer widths, `Double`, `Float`, `Bool`, `UUID`, `[UInt8]` (`bytea`),
  `Decimal` (`numeric`), `Date` (`timestamp`/`timestamptz`/`date`), JSON
  (`json`/`jsonb`) via `Codable` (`PostgresJSON` to bind, `decodeJSON` to read),
  and **arrays** of these (`decodeArray`/`decodeNullableArray`), in both binary
  and text format. Also `money`→`Decimal`, `time`/`timetz`→`PostgresTime`,
  `interval`→`PostgresInterval`, and `inet`/`cidr`→`PostgresInet`. The built-in
  **geometric types** map to typed values: `point`→`PostgresPoint`,
  `line`→`PostgresLine`, `lseg`→`PostgresLineSegment`, `box`→`PostgresBox`,
  `path`→`PostgresPath`, `polygon`→`PostgresPolygon`, `circle`→`PostgresCircle`,
  in both binary and text format. **PostGIS** `geometry`/`geography`→`PostgresGeometry`
  (a full Extended Well-Known Binary codec covering point, linestring, polygon,
  multipoint, multilinestring, multipolygon, and geometry collection, with SRID
  and Z/M dimensions); PostGIS is a PostgreSQL extension, so this type is
  PostgreSQL-only — the built-in geometric types above are the cross-database
  ones. Any other type is retrievable as its text via `String` (simple query) or
  a `::text` cast. SQL NULL is surfaced as `PostgresColumnValue`, never an
  optional.
- **JSON workflow**: store a `Codable` value as `jsonb` (`PostgresJSON`), index it
  (`CREATE INDEX … USING gin`), query by field (`->>`) or containment (`@>`), and
  decode the document back (`decodeJSON`).
- **Serialization-failure retry**: a single query that hits `40001` (serialization
  failure / YugabyteDB read-restart) or `40P01` (deadlock) is retried by the
  resilience layer.
- **Row-to-`struct` mapping**: `row.decode(MyStruct.self)` reads each property
  from the column of the same name (nested structs map from JSON columns).
- **Prepared-statement caching** per connection: a repeated SQL string reuses
  the server-side prepared statement and skips re-parsing.
- **Transactions**: `withTransaction { tx in … }` commits once on success and
  rolls back on a thrown error. Wrapping a bulk insert this way is dramatically
  faster than autocommit (a local benchmark rose from ~280 to ~8,000 inserts/s).
- **Bulk load** with `copyIn(into:columns:rows:)` (`COPY … FROM STDIN`) — the
  fastest ingest path (~293,000 rows/s in the same local benchmark), with NULL
  and special-character escaping handled.
- A bounded **acquire timeout**: a saturated pool fails a waiting caller with
  `poolExhausted` instead of hanging.
- **Self-healing resilience** (`PostgresResilience`, on by default): a single
  query that hits a dropped/half-open connection, a brief server restart, or a
  momentarily full pool is retried on a freshly acquired connection with
  exponential backoff within the request-timeout budget. A live test that
  restarts the server mid-run completes every query with zero failures.
  Retries are at-least-once for mid-flight drops; use `.disabled` for
  non-idempotent single statements outside a transaction. Transactions, COPY,
  and streams are not auto-retried.
- ServiceLifecycle `Service` conformance and an ambient-client binding.
- **Observability** across all three pillars, hands-off once the application
  bootstraps its backends:
  - **Logging** through the injected `swift-log` `Logger`: connecting/connected/
    connect-failed, query started/completed/failed with latency, retry scheduled,
    pool exhausted, pool shutdown. Failures, retries, and pool exhaustion log at
    error/warning/notice; per-query and connection-lifecycle detail is `debug`.
  - **Tracing** via `swift-distributed-tracing`: one client span per query
    carrying the OpenTelemetry `db.system`/`db.operation`/`db.statement`
    attributes, auto-nesting under the caller's span. No tracer bootstrapped ⇒
    no-op.
  - **Metrics** via `swift-metrics`, emitted automatically (no polling) to the
    bootstrapped backend: counters `postgres.queries`, `postgres.query.errors`,
    `postgres.query.retries`, `postgres.pool.timeouts`,
    `postgres.connections.opened`; a `postgres.query.duration` timer; and
    `postgres.pool.idle`/`postgres.pool.in_use` gauges. The same data is also
    available pull-based via `client.metrics()` (`PostgresClientMetrics`) and
    `client.poolStats()` (`PostgresPoolStats`) for callers not using swift-metrics.

  Bootstrap `MetricsSystem`, `LoggingSystem`, and `InstrumentationSystem` once at
  startup, before constructing the client; everything then flows with no per-query
  wiring. With no backend bootstrapped, all instruments are no-ops.

Planned: binary parameter encoding, pipelining, `LISTEN`/`NOTIFY`, and YugabyteDB
cluster-aware connection load balancing.

## Usage

```swift
import DXPostgres

let configuration = PostgresConfiguration(
    endpoint: PostgresEndpoint(host: "localhost"),
    credentials: .password(username: "postgres", password: "secret"),
    database: PostgresDatabaseName("appdb")
)

try await Postgres.withClient(configuration) { postgres in
    let result = try await postgres.query(
        "SELECT id, name FROM accounts WHERE id = $1",
        binding: [42]
    )
    for row in result.rows {
        let id = try row.decode(Int.self, named: "id")
        let name = try row.decode(String.self, named: "name")
        print(id, name)
    }
}
```
