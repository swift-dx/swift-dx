# DXPostgres

A native, pure-Swift PostgreSQL client. It speaks the PostgreSQL v3
frontend/backend protocol directly over a socket — no libpq, no PostgresNIO.
The design keeps each connection strictly synchronous (a connection is a serial
resource; async on the wire is pure overhead) and puts concurrency in the pool
above it, so a leased unit of work runs at the speed of a hand-rolled C client
while callers keep a plain `async` API.

## What it does

- **Connect** over plaintext TCP with trust, cleartext, MD5, or SCRAM-SHA-256
  authentication, behind a bounded connection pool.
- **Run statements** — `execute` for raw SQL, a parameterized `query` whose
  interpolated values are bound rather than spliced, and `query(_:as:)` that
  decodes rows straight into your `Decodable` types.
- **Group work into transactions** with `transaction { tx in … }`: commit on
  return, roll back on a thrown error — with no connection to manage.
- **Publish and subscribe** over `NOTIFY` channels — `notify` to send, `subscribe`
  to receive — including a `watchTable` helper that installs a change-capture
  trigger with an optional server-side filter.

## Install

Add the package and depend on the `DXPostgres` product:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swift-dx/swift-dx", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "DXPostgres", package: "swift-dx"),
    ]),
]
```

```swift
import DXPostgres
```

## Connecting

A `PostgresConfiguration` holds everything needed to open the pool. Pass an empty
password for a trust role.

```swift
let configuration = PostgresConfiguration(
    host: "127.0.0.1", port: 5432, username: "app", password: "",
    database: "app", applicationName: "myapp", searchPath: .serverDefault,
    poolSize: 8, maxSubscriptions: 16
)
```

`searchPath` scopes how every connection resolves unqualified names, set once in
the startup packet so no per-query qualification or per-transaction `SET` is
needed. `.serverDefault` leaves the server's configured path untouched;
`.schemas(["app", "public"])` resolves unqualified names against those schemas in
order. To splice a schema, table, or column name into a statement (a parameter
can only stand for a value, never an identifier), use `\(identifier:)`, which
emits a quoted identifier rather than a bound parameter:

```swift
let rows = try await Postgres.query(
    "SELECT id FROM \(identifier: schema).\(identifier: table) WHERE email = \(email)",
    as: User.self
)
```

Open the pool once and **bind it as the ambient client**. From then on, code
anywhere in that task tree calls `Postgres` directly — it never sees the instance
or a connection.

In a server, run the pool as a ServiceLifecycle `Service` (so it is torn down on
`SIGTERM`/`SIGINT`) and bind it for the lifetime of the group:

```swift
let postgres = try Postgres.service(configuration)
let group = ServiceGroup(services: [postgres, httpServer], logger: logger)

try await Postgres.withCurrent(postgres) {   // bound for everything run inside
    try await group.run()
}
```

ServiceLifecycle is not required. In a script, CLI, worker, or test, bind a
plain client around your work the same way:

```swift
let postgres = try Postgres.connect(configuration)
defer { postgres.shutdown() }

try await Postgres.withCurrent(postgres) {
    try await runApp()
}
```

Either way, anywhere inside the bound body — no instance passed, no connection in
sight:

```swift
func activeUsers() async throws -> PostgresResult {
    try await Postgres.execute("SELECT count(*) FROM users WHERE active")
}
```

`Postgres.connect`/`service` return `some PostgresClient`, so the concrete pool
type stays hidden, and `Postgres.current()` throws
`PostgresError.noCurrentClient` if nothing is bound — no null, no trap. If you
prefer an explicit handle — for code outside the bound task tree, such as a
`Task.detached` — keep the returned value and call `postgres.execute` /
`postgres.query` / `postgres.transaction` on it directly.

## Resilience

The pool heals itself, so a server outage does not take the process down with it.
When a statement fails because its connection broke, that connection is marked
down and a background task reconnects it — forever, with capped exponential
backoff — returning it to service the moment the server is reachable again. A
connection lost is logged once at `warning`, a connection recovered once at
`notice`, through swift-log; there is no per-attempt log spam while a server is
offline.

While a connection is down it is simply not handed out. Calls keep using the
healthy connections. If every connection is down, a call does not block for a
timeout — it fails fast with `PostgresError.allConnectionsDown`, which is
transient, so retrying once the server returns succeeds. The reconnection never
gives up, so a database that is offline for a day and then returns needs no
restart or intervention on the client side.

## Running queries

```swift
// Raw statement, owned result:
let result = try await Postgres.execute("SELECT id, email FROM users")

// Parameterized — interpolated values are bound parameters, never spliced into
// the SQL, so even an injection string is just data:
let email = userInput
let rows = try await Postgres.query("SELECT id, email FROM users WHERE email = \(email)")

// Decoded straight into your Decodable type:
struct Account: Decodable, Sendable {

    let id: Int
    let email: String
    let active: Bool
}

let accounts = try await Postgres.query(
    "SELECT id, email, active FROM accounts WHERE email = \(email)",
    as: Account.self
)
```

Each `\(value)` becomes a `$1`, `$2`, … bound over the extended protocol. Use
`query(statement)` for an untyped `PostgresResult`, or `result.decode(as:)` to
decode a result you already have.

## Reading results

A `PostgresResult` is the column descriptions (name, type OID, wire format) sent
once, paired with rows. Each field is a `PostgresCell` — `.bytes([UInt8])` or
`.sqlNull`, a named value rather than an optional:

```swift
let result = try await Postgres.execute("SELECT id, email FROM users")
let emailColumn = try result.columnIndex(named: "email")
for row in result.rows {
    let id = try row[0].text()
    let email = row[emailColumn].isNull ? "(none)" : try row[emailColumn].text()
    print(id, email)
}
```

For the hot path, the streaming form `execute(_:onRow:)` — available on a
transaction's `tx` and on a strictly-serial `PostgresDirectConnection` — hands
each row to a closure read in place from the read buffer, with no per-row
allocation; you copy out only the fields you keep:

```swift
try connection.execute("SELECT id, name FROM users") { row in
    let id = try row.int64(0)       // parsed in place, no allocation
    let name = try row.text(1)      // copies only this field
}
```

`queryScalarInt64` reads a single `int8` straight off the wire over the extended
protocol with a binary result and zero allocation.

## Transactions

`transaction` runs a closure as one unit of work. Every statement inside runs on
a single connection, in order, between a `BEGIN` and a `COMMIT`. Returning from
the closure commits; throwing rolls back and rethrows your error. There is no
connection to acquire, hold, or release — that is handled for you.

```swift
try await Postgres.transaction { tx in
    try tx.execute("UPDATE accounts SET balance = balance - \(amount) WHERE id = \(from)")
    try tx.execute("UPDATE accounts SET balance = balance + \(amount) WHERE id = \(to)")
}   // committed on return; rolled back if either statement, or your own check, throws

// Throw your own error to roll back and recover it unchanged:
do {
    try await Postgres.transaction { tx in
        let balance = try tx.queryScalarInt64("SELECT balance FROM accounts WHERE id = \(from)::int8", value: 0)
        guard balance >= amount else { throw PaymentError.insufficientFunds }
        try tx.execute("UPDATE accounts SET balance = balance - \(amount) WHERE id = \(from)")
    }
} catch PaymentError.insufficientFunds {
    // the transaction rolled back; your error reached you intact
}
```

The same statements are available on `tx` as on `Postgres` — `execute`, `query`,
`query(_:as:)` — so a transaction reads exactly like ad-hoc work, just grouped.
If you hold an explicit client instead of using the ambient one, it is the same
call on the instance: `client.transaction { tx in … }`.

## Subscriptions

A channel is a named, shared mailbox. Something **publishes** a payload on it with
`NOTIFY` / `pg_notify`, and every session **subscribed** to that channel at that
moment receives it. The two ends are independent: publish and subscribe each name
the same channel string and otherwise know nothing about each other.

Publish from the pooled client — it is an ordinary statement, so it needs no
dedicated connection:

```swift
try await Postgres.notify(channel: "cache_invalidation", payload: "user:42")
```

Subscribe to one or more channels. With the ambient client bound, a subscription
needs no configuration of its own — it reuses the bound client's settings. The
returned listener owns a single dedicated connection that can carry many channels
at once, and `listen` / `unlisten` add or drop channels on the live subscription:

```swift
// Subscribe to raw channels (published by your own notify / pg_notify, another
// service, or a trigger):
let subscription = try Postgres.subscribe(channels: ["cache_invalidation"])
for try await note in subscription.notifications {
    handle(note.payload)
}
```

`watchTable` is the same subscribe machinery with the publish side filled in for
you: it installs a row-change trigger that publishes each change on a channel
derived from the table name, then subscribes. The `where` filter runs in the
server, so only matching changes reach you, each as JSON `{"op":"UPDATE","row":{…}}`:

```swift
let watch = try Postgres.watchTable(table: "orders", where: "NEW.status = 'paid'")
for try await change in watch.notifications {
    handle(change.payload)
}
```

Both also take an explicit `PostgresConfiguration` (`Postgres.subscribe(configuration,
channels:)`, `Postgres.watchTable(configuration, table:)`) for use outside a bound
task tree.

Each notification the subscription yields is delivered to the async stream;
ending the stream tears the subscription down. The subscription manages its own
connection and heals itself: if the connection drops it reconnects in the
background forever with capped backoff and re-issues every active channel before
resuming.

Because each subscription holds a dedicated connection, ambient `subscribe` and
`watchTable` are bounded by the client's `maxSubscriptions`. Opening one past the
limit fails fast with `PostgresError.subscriptionLimitReached`, and closing a
subscription frees the slot — so the subscription side has a hard ceiling the same
way `poolSize` caps the query side, and the total connection footprint stays within
`poolSize + maxSubscriptions`. One connection can carry many channels, so prefer a
single `subscribe(channels: […])` with several channels over one subscription per
channel. The host- and configuration-based `subscribe`/`watchTable` overloads are
unbounded by design — they are the explicit escape hatch for callers managing their
own connection budget.

Delivery is ephemeral and at-most-once: a notification reaches only the sessions
listening when it is sent, is not stored, and is not replayed — a subscriber that
is disconnected or reconnecting at that instant misses it. For durable, replayable
delivery, use a table-as-queue or a dedicated broker rather than `NOTIFY`. Channel
names are exact strings, with no wildcard or pattern matching; to route by topic,
publish to a fixed set of channels or carry the topic in the payload and filter on
receipt.

## Status

This is the lean, high-performance core. Current scope:

- Plaintext only; TLS is not yet on this path.
- The zero-allocation typed fast path covers `Int64`; a generalized
  `queryScalar<T>` / typed-row family is planned.
- `query(_:)` binds parameters over the extended protocol with text results and
  decodes rows into `Decodable` types; binary result encoding to bring it onto
  the scalar fast path's ceiling is planned.

## Dependencies

`DXCore`, swift-nio (`NIOCore`, for `ByteBuffer`), swift-crypto (`Crypto`, for
SCRAM/MD5), swift-log (`Logging`, for connection-lifecycle events such as a lost
or recovered connection), swift-metrics and swift-distributed-tracing (`Metrics`,
`Tracing`, for the observability described below), and swift-service-lifecycle
(`ServiceLifecycle`, for running the pool as a managed `Service`). No event loop,
no atomics package, no TLS stack on the query path.

## Observability

The ambient `Postgres.execute` / `query` / `transaction` / `notify` surface is
instrumented with swift-distributed-tracing and swift-metrics. Each call opens a
client-kind span (`postgres.execute`, `postgres.query`, …) tagged with
`db.system` and `db.operation`, increments a `postgres.operations` counter, and
records a `postgres.operation.duration` timer; failures add to
`postgres.operation.errors` and are recorded on the span. When an application has
bootstrapped a tracer and a metrics backend, these are picked up automatically and
the spans nest under the application's own; when it has not, both are no-ops.

Instrumentation lives only on the ambient convenience surface. The pooled client's
own methods, the direct connection, and the zero-allocation scalar path carry no
telemetry, so their benchmarked throughput is unchanged — reach for those when you
need the last microsecond, and for the ambient surface when you want the spans.

## Performance

Measured against C/libpq under identical conditions: same box (PostgreSQL 18.4,
localhost, plaintext), same query (`SELECT $1::int8`, prepared, binary result),
back to back. C uses `PQexecPrepared`; the pool comparison uses a libpq pool of
the same size driven by the same number of client threads.

### Single connection, point query

| metric | DXPostgres (scalar) | C/libpq |
|---|--:|--:|
| throughput | **31,349 q/s** | 28,445 q/s |
| p50 latency | **31 µs** | 33 µs |
| user-CPU / query | **3.4 µs** | 4.1 µs |
| allocations / query | **0** | ~1–2 |

The general read paths trade ergonomics for that ceiling: `execute` (simple
query, text, owned result) runs ~23k q/s at 5 allocations, and the streaming
form ~24k q/s at 2 allocations with zero per-row and per-field allocation.

### Under contention — pool of 10 connections, rising client count

Aggregate throughput (queries/sec, median of 3):

| clients | C/libpq | async pool | **lease pool** |
|--:|--:|--:|--:|
| 10 | 237,479 | 163,686 | **259,080** |
| 100 | 151,090 | 225,490 | **273,167** |
| 1,000 | 149,746 | 231,168 | **280,040** |
| 10,000 | 143,038 | 226,762 | **256,287** |

The lease pool holds the synchronous core's ceiling under load — it pays the
pool lock and the async hand-off once per leased unit of work rather than once
per query, so it stays near 260–280k from 10 to 10,000 clients while a
per-query pool (libpq's and the async-per-call pool's weak point) falls toward
150k. At 10,000 concurrent clients over 10 connections it is ~80% ahead of
libpq, with no collapse.
