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

## Leases and transactions

`withConnection` pins one connection for a unit of work — the basis for
transactions and multi-statement sessions:

```swift
try await pool.withConnection { connection in
    // every statement here runs on the same connection, synchronously
}
```

## LISTEN / NOTIFY and table watching

```swift
// Watch a table; the WHEN filter runs in the server, so only matching changes
// reach the client, each as JSON: {"op":"UPDATE","row":{…}}.
let watch = try Postgres.watchTable(
    host: "127.0.0.1", port: 5432, username: "app", password: "", database: "app",
    applicationName: "watcher", table: "orders", channel: "order_changes",
    where: "NEW.status = 'paid'"
)
for try await change in watch.notifications {
    handle(change.payload)
}

// Or subscribe to raw channels (your own NOTIFY / pg_notify):
let listener = try Postgres.listen(host: …, channels: ["cache_invalidation"])
for try await note in listener.notifications { … }
```

A listener owns a dedicated connection parked in a blocking receive loop on its
own thread; each notification is yielded to the async stream. Ending the stream
closes the connection.

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

`DXCore`, swift-nio (`NIOCore`, for `ByteBuffer`), and swift-crypto (`Crypto`,
for SCRAM/MD5). No event loop, no atomics package, no TLS stack on the query
path.

## Status

This is the lean, high-performance core. Current scope:

- Plaintext only; TLS is not yet on this path.
- The zero-allocation typed fast path covers `Int64`; a generalized
  `queryScalar<T>` / typed-row family is planned.
- `execute` runs the simple-query protocol (text results); a prepared, binary,
  parameterized general `query` is planned to bring the general path onto the
  fast path's ceiling.
