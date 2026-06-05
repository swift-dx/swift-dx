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
- **Subscribe** to `NOTIFY` channels, including a `watchTable` helper that
  installs a change-capture trigger with an optional server-side filter.

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
    database: "app", applicationName: "myapp", poolSize: 8
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
SCRAM/MD5), and swift-service-lifecycle (`ServiceLifecycle`, for running the pool
as a managed `Service`). No event loop, no atomics package, no TLS stack on the
query path.

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
