# DXPostgres

A native, pure-Swift PostgreSQL client. It speaks the PostgreSQL v3
frontend/backend protocol directly over a socket — no libpq, no PostgresNIO.
The design keeps each connection strictly synchronous (a connection is a serial
resource; async on the wire is pure overhead) and puts concurrency in the pool
above it, so a leased unit of work runs at the speed of a hand-rolled C client
while callers keep a plain `async` API.

## What it does

- **Connect** over plaintext TCP with trust, cleartext, MD5, or SCRAM-SHA-256
  authentication.
- **Run any statement** and read rows back as raw bytes, decoded text, or
  parsed integers — owned or streamed.
- **Pool** connections behind a lease so a transaction or a batch holds one
  connection and pays the async hand-off once per unit of work, not per query.
- **`LISTEN`/`NOTIFY`**, including a `watchTable` helper that installs a
  change-capture trigger with an optional server-side filter.

## Quick start

```swift
import DXPostgres

let postgres = try Postgres.connect(
    host: "127.0.0.1", port: 5432,
    username: "app", password: "", database: "app",
    applicationName: "myapp", poolSize: 4
)
defer { postgres.shutdown() }

let result = try await postgres.execute("SELECT id, email FROM users")
let emailColumn = try result.columnIndex(named: "email")
for row in result.rows {
    let id = try row[0].text()
    let email = row[emailColumn].isNull ? "(none)" : try row[emailColumn].text()
    print(id, email)
}
```

`Postgres.connect` returns `some PostgresClient`; the concrete pool type stays
hidden. Use a trust role by passing an empty password.

## Parameterized and typed queries

Interpolated values are bound parameters, never spliced into the SQL, and rows
decode straight into your `Decodable` types:

```swift
struct Account: Decodable, Sendable {

    let id: Int
    let email: String
    let active: Bool
}

let email = userInput   // even an injection string is just data
let accounts = try await postgres.query(
    "SELECT id, email, active FROM accounts WHERE email = \(email)",
    as: Account.self
)
```

Each `\(value)` becomes a `$1`, `$2`, … bound over the extended protocol. Use
`query(statement)` for an untyped `PostgresResult`, or `result.decode(as:)` to
decode an existing result.

## Reading results: three shapes, one core

A query result is the column descriptions (name, type OID, wire format) sent
once, paired with rows. The streaming primitive is the core; the owned result
is that stream collected.

```swift
// Owned — keep everything. Each field is a PostgresCell (.bytes([UInt8]) or .sqlNull).
let result = try await postgres.execute("SELECT id, name FROM users")

// Streamed — borrowed rows read in place from the read buffer, ~0 allocation per row.
try connection.execute("SELECT id, name FROM users") { row in
    let id = try row.int64(0)       // parsed in place, no allocation
    let name = try row.text(1)      // copies only this field
}

// Streamed, collected into a variable — pay only for what you keep.
var names: [String] = []
try connection.execute("SELECT name FROM users") { row in names.append(try row.text(0)) }
```

For the hot path of a single typed value, `queryScalarInt64` runs the extended
protocol with a binary result and reads the integer straight off the wire with
zero allocation.

## Transactions

`transaction` runs a closure as one unit of work. Every statement inside runs on
a single connection, in order, between a `BEGIN` and a `COMMIT`. Returning from
the closure commits; throwing rolls back and rethrows your error. There is no
connection to acquire, hold, or release — that is handled for you.

```swift
try await postgres.transaction { tx in
    try tx.execute("UPDATE accounts SET balance = balance - \(amount) WHERE id = \(from)")
    try tx.execute("UPDATE accounts SET balance = balance + \(amount) WHERE id = \(to)")
}   // committed on return; rolled back if either statement, or your own check, throws

// Throw your own error to roll back and recover it unchanged:
do {
    try await postgres.transaction { tx in
        let balance = try tx.queryScalarInt64("SELECT balance FROM accounts WHERE id = \(from)::int8", value: 0)
        guard balance >= amount else { throw PaymentError.insufficientFunds }
        try tx.execute("UPDATE accounts SET balance = balance - \(amount) WHERE id = \(from)")
    }
} catch PaymentError.insufficientFunds {
    // the transaction rolled back; your error reached you intact
}
```

The same statements are available on `tx` as on the client — `execute`, `query`,
`query(_:as:)` — so a transaction reads exactly like ad-hoc work, just grouped.
Through the ambient client it is `Postgres.transaction { tx in … }`, with no
client or connection passed in.

## Configuration, service lifecycle, and ambient access

Configure once, run as a ServiceLifecycle `Service`, and reach the pool from
anywhere via a task-local ambient binding:

```swift
let configuration = PostgresConfiguration(
    host: "127.0.0.1", port: 5432, username: "app", password: "",
    database: "app", applicationName: "myapp", poolSize: 8
)

// A client that is also a Service — add it to a ServiceGroup so the pool is
// torn down on graceful shutdown (SIGTERM/SIGINT).
let postgres = try Postgres.service(configuration)
let group = ServiceGroup(services: [postgres, httpServer], logger: logger)

// Bind it as the ambient client; code deep in the call tree reads it back.
try await Postgres.withCurrent(postgres) {
    try await group.run()
}

// Anywhere inside that task tree — no one had to be handed the pool:
func activeUserCount() async throws -> PostgresResult {
    try await Postgres.execute("SELECT count(*) FROM users WHERE active")
}
```

`Postgres.current()` returns the bound client, or throws
`PostgresError.noCurrentClient` when nothing is bound — no null, no trap.

## Subscriptions

```swift
// Subscribe to raw channels (your own NOTIFY / pg_notify) — reuse the same
// configuration you built for the pool:
let subscription = try Postgres.subscribe(configuration, channels: ["cache_invalidation"])
for try await note in subscription.notifications {
    handle(note.payload)
}

// Watch a table; the WHEN filter runs in the server, so only matching changes
// reach you, each as JSON: {"op":"UPDATE","row":{…}}.
let watch = try Postgres.watchTable(configuration, table: "orders", channel: "order_changes", where: "NEW.status = 'paid'")
for try await change in watch.notifications {
    handle(change.payload)
}
```

Each notification the subscription yields is delivered to the async stream;
ending the stream tears the subscription down. The subscription manages its own
connection.

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

## Dependencies

`DXCore`, swift-nio (`NIOCore`, for `ByteBuffer`), swift-crypto (`Crypto`, for
SCRAM/MD5), and swift-service-lifecycle (`ServiceLifecycle`, for running the pool
as a managed `Service`). No event loop, no atomics package, no TLS stack on the
query path.

## Status

This is the lean, high-performance core. Current scope:

- Plaintext only; TLS is not yet on this path.
- The zero-allocation typed fast path covers `Int64`; a generalized
  `queryScalar<T>` / typed-row family is planned.
- `query(_:)` binds parameters over the extended protocol with text results and
  decodes rows into `Decodable` types; binary result encoding to bring it onto
  the scalar fast path's ceiling is planned.
