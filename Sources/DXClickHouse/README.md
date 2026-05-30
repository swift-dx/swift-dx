<!--
===----------------------------------------------------------------------===
This source file is part of the SwiftDX open source project

Copyright (c) 2026 SwiftDX Contributors
Licensed under Apache License v2.0. See LICENSE for license information.

SPDX-License-Identifier: Apache-2.0
===----------------------------------------------------------------------===
-->

# DXClickHouse

Swift native ClickHouse client. Native POSIX-socket transport,
zero-allocation view types.

## Quick start

```swift
import DXClickHouse

let client = try await ClickHouse.connect(.init(endpoints: [.init(host: "ch", port: 9000)]))
let users: [User] = try await client.selectAll("SELECT id, name FROM users", as: User.self)
await client.close()
```

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swift-dx/swift-dx", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(
        name: "MyService",
        dependencies: [
            .product(name: "DXClickHouse", package: "swift-dx"),
        ]
    ),
]
```

```swift
import DXClickHouse
```

## Core concepts

### Transport

`DXClickHouse` speaks the ClickHouse Native binary protocol over a
direct POSIX socket. No NIO, no event loop, no TLS at this stage. Each
connection owns one OS-level socket and a private `DispatchQueue`
worker; the worker serialises every wire round-trip so a single
`ClickHouseClient` can be shared safely across concurrent async tasks.

### Connection pool

`ClickHouseConnectionPool` is a production-grade pool over the same
underlying connection type. Features:

- **Multi-endpoint round-robin failover.** Configure an ordered list of
  endpoints; the pool rotates across them when opening, and on connect
  failure it transparently fails over to the next entry. Only when
  every endpoint has been tried does `ClickHouseError.endpointsExhausted`
  surface.
- **Idle TTL + max lifetime eviction.** Connections sitting idle longer
  than `idleConnectionTTL`, or whose total lifetime exceeds
  `maxConnectionLifetime`, are closed and replaced. A background sweep
  task evicts stale entries even when the pool is briefly cold.
- **Preflight ping.** Optional `Ping → Pong` round-trip on a recycled
  idle connection before it is handed to the caller. Stale sockets
  (server restart, network partition) are discarded and replaced.
- **Bounded acquire.** Saturated pool callers wait up to
  `acquireTimeout` before `Failure.acquireTimedOut` fires.

### Reconnect

Every connection carries a `ReconnectionPolicy`. The default is
`.alwaysRetry`: on a transient I/O failure (EPIPE, ECONNRESET,
pre-send unexpected EOF) the connection layer closes the socket,
sleeps for an exponentially-backed-off interval capped at 5 seconds,
and re-handshakes — indefinitely. Callers who prefer to surface the
first failure to the application use `.failFast`, or supply a bounded
budget via `.custom(initial:max:multiplier:attempts:)`.

### Per-query timeout

Every public operation on `ClickHouseClient` takes a `timeout: Duration`
parameter. The defaults live in `ClickHouseQueryDefaults`:

| Operation | Default |
|-----------|---------|
| `select`, `scalar`, `selectAll`, `execute` | 30 seconds |
| `insert` | 60 seconds |
| `ping` | 5 seconds |
| `stream` (continuous read) | 5 minutes |

When the deadline fires, the helper throws
`ClickHouseError.queryTimeout(elapsed:)`, shuts down the live socket
so the in-flight `recv()` / `send()` returns immediately, and lets the
reconnect path open a fresh socket for the next call. The server-side
`max_execution_time` setting is injected into the query so the server
itself stops processing even if the local cancel race loses.

Pass `timeout: .zero` to disable the deadline for one call.

### View types

For the hot path, the wire-decoder layer exposes zero-allocation view
types backed by the wire buffer (e.g. `ClickHouseFixedStringView`,
`ClickHouseMapView`). They let row-by-row consumers iterate result
blocks without materialising `String`, `[UInt8]`, or `Dictionary`
copies until a value is actually read. Use the typed Codable surface
for ergonomics; reach for the view types when allocation overhead
dominates decode time in a profile.

## Usage patterns

### Ad-hoc (scripts, jobs, tests)

Short-lived script-style usage. Open a client, run work, close it.

```swift
import DXClickHouse

let client = try await ClickHouse.connect(.init(
    endpoints: [.init(host: "ch", port: 9000)],
    user: "default",
    password: "",
    database: "analytics"
))
let count: UInt64 = try await client.scalar("SELECT count() FROM events", as: UInt64.self)
await client.close()
```

Or with a scoped helper that always closes the client, even on throw:

```swift
try await ClickHouse.withClient(.init(endpoints: [.init(host: "ch", port: 9000)])) { client in
    try await client.insert(into: "events", rows: batch)
}
```

### Service-lifecycle (production services)

`ClickHouseService` integrates with `swift-service-lifecycle`. The
service eagerly opens its underlying `ClickHouseClient` (so the
`client` accessor is valid the moment the service has been
constructed), then parks until the surrounding `ServiceGroup` signals
graceful shutdown. On signal, in-flight queries are allowed up to
`shutdownGracePeriod` to drain before the connection is closed.

```swift
import DXClickHouse
import ServiceLifecycle

let service = try await ClickHouseService(configuration: .init(
    endpoints: [.init(host: "ch-1", port: 9000), .init(host: "ch-2", port: 9000)],
    user: "service",
    password: secret,
    database: "analytics",
    shutdownGracePeriod: .seconds(30)
))

let group = ServiceGroup(services: [service, httpService], logger: logger)
try await group.run()

// From a request handler:
let orders: [Order] = try await service.client.selectAll(
    "SELECT id, total FROM orders WHERE day = {day:Date}",
    as: Order.self,
    parameters: .init([.init(name: "day", value: "2026-05-30")])
)
```

## Operations and overloads

Every operation that takes a payload (SQL bytes, row collections,
scalar replies) is offered in the canonical SwiftDX input forms. The
performance primitive is the raw `[UInt8]` form; every other overload
converts to the primitive and delegates. No NIO `ByteBuffer` overload
is offered — adding a NIO dependency for one convenience type would
defeat the purpose of the POSIX-socket transport.

### `select` — streamed multi-row read

Returns an `AsyncThrowingStream` that yields one decoded row at a time.
Each result block is parsed into typed columns once, then rows are
vended individually.

```swift
// String SQL
for try await user in client.select("SELECT id, name FROM users", as: User.self) {
    handle(user)
}

// Raw bytes SQL (zero-copy from the call site)
let sqlBytes: [UInt8] = Array("SELECT id, name FROM users".utf8)
for try await user in client.select(sqlBytes, as: User.self) {
    handle(user)
}

// Callback delivery of the fully-collected result
client.select("SELECT id, name FROM users", as: User.self) { (result: Result<[User], ClickHouseError>) in
    handle(result)
}

// DXMessageHandler — continuous, with per-stream timeout
let task = client.stream("SELECT id, name FROM users", as: User.self, handler: myHandler)
```

### `selectAll` — eager multi-row read

Collects every row into an array and returns once the server emits
EndOfStream.

```swift
let users: [User] = try await client.selectAll("SELECT id, name FROM users", as: User.self)
```

### `scalar` — one-row, one-column read

Used for `SELECT count()`, `SELECT now()`, single-aggregate queries.
Throws if the result shape is not exactly 1×1.

```swift
let total: UInt64 = try await client.scalar("SELECT count() FROM events", as: UInt64.self)

// Callback
client.scalar("SELECT count() FROM events", as: UInt64.self) { (result: Result<UInt64, ClickHouseError>) in
    handle(result)
}
```

### `insert` — typed columnar INSERT

Encodes Encodable rows columnarly, performs the INSERT handshake, and
returns the server-reported written-row / written-byte counters.

```swift
struct Order: Codable, Sendable {
    let id: UInt64
    let total: Decimal
}

// [T] — the primitive
let summary = try await client.insert(into: "orders", rows: [
    Order(id: 1, total: 19.99),
    Order(id: 2, total: 29.99),
])

// Sequence
let summary = try await client.insert(into: "orders", rows: ordersSet)

// AsyncSequence
let summary = try await client.insert(into: "orders", rows: incomingStream)

// Callback
client.insert(into: "orders", rows: rows) { (result: Result<ClickHouseInsertSummary, ClickHouseError>) in
    handle(result)
}

// Pre-encoded Native block bytes (max throughput when you already
// have a columnar buffer from somewhere else)
let summary = try await client.insertNativeBlock(
    into: "orders",
    columnList: "(id, total)",
    nativeBlockBytes: preEncoded
)
```

### `execute` — fire SQL, ignore the result body

For DDL (`CREATE TABLE`, `ALTER`, `OPTIMIZE`, etc.) and other queries
whose return value is not needed.

```swift
try await client.execute("OPTIMIZE TABLE events FINAL")
try await client.execute(Array("OPTIMIZE TABLE events FINAL".utf8))

client.execute("OPTIMIZE TABLE events FINAL") { (result: Result<Void, ClickHouseError>) in
    handle(result)
}
```

### `ping` — health check

Single round-trip. Cheap. Used by the pool's preflight check and by
service liveness probes.

```swift
try await client.ping()
client.ping { (result: Result<Void, ClickHouseError>) in
    handle(result)
}
```

### Server-side parameters

Use `ClickHouseQueryParameters` for SQL-injection-safe substitution
via ClickHouse's `{name:Type}` syntax. The server validates the value
against the declared type.

```swift
let orders: [Order] = try await client.selectAll(
    "SELECT id, total FROM orders WHERE id = {id:UInt64}",
    as: Order.self,
    parameters: .init([.init(name: "id", value: "42")])
)
```

### Per-query settings

Use `ClickHouseQuerySettings` to override server-side settings for
the duration of one query.

```swift
let rows: [Event] = try await client.selectAll(
    "SELECT id FROM events",
    as: Event.self,
    settings: .init([.init(name: "max_threads", value: "8")])
)
```

## Configuration reference

### `ClickHouseConfiguration`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `endpoints` | `[ClickHouseEndpoint]` | (required) | One or more `host:port` pairs. Multi-entry lists enable round-robin failover at the pool layer. |
| `user` | `String` | `"default"` | Authentication user applied to every connection. |
| `password` | `String` | `""` | Password applied to every connection. |
| `database` | `String` | `"default"` | Default database for queries that do not qualify table names. |
| `shutdownGracePeriod` | `Duration` | `.seconds(30)` | Maximum time `ClickHouseService` allows in-flight work to drain on graceful shutdown. |
| `logger` | `Logger` | no-op | `swift-log` destination for service-level lifecycle events. |

### `ClickHouseConnectionPool.Configuration`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `endpoints` | `[ClickHouseEndpoint]` | (required) | One or more `host:port` pairs. The pool round-robins across them on every new connection. |
| `user`, `password`, `database` | `String` | as above | Auth context applied to every pooled connection. |
| `minConnections` | `Int` | `1` | Number of connections opened eagerly during pool initialisation. |
| `maxConnections` | `Int` | `16` | Hard upper bound on concurrent connections. Saturated callers wait. |
| `acquireTimeout` | `Duration` | `.seconds(30)` | Maximum wait when the pool is saturated before `Failure.acquireTimedOut`. |
| `idleConnectionTTL` | `Duration` | `.seconds(300)` | Idle entries older than this are evicted. |
| `maxConnectionLifetime` | `Duration` | `.seconds(3600)` | Hard cap on total connection age, even when in active use. |
| `preflightPing` | `Bool` | `false` | Round-trip `Ping → Pong` on recycled idle entries before handing them back. |
| `evictionInterval` | `Duration` | `.seconds(30)` | Background sweep cadence for idle/lifetime eviction. |

### `ReconnectionPolicy`

| Field | Type | Description |
|-------|------|-------------|
| `maxAttempts` | `Int` | Maximum reconnect attempts. `0` disables reconnect (fail-fast). `unboundedAttempts` retries indefinitely. |
| `initialBackoff` | `Duration` | Backoff before the first retry. |
| `maxBackoff` | `Duration` | Cap on backoff between attempts. |
| `backoffMultiplier` | `Double` | Factor each attempt multiplies the current backoff by. |

Convenience values: `.alwaysRetry` (the library default — 100ms initial,
5s cap, unbounded attempts), `.failFast` (no retries),
`.custom(initial:max:multiplier:attempts:)`.

### `ClickHouseQueryDefaults`

| Field | Type | Default | Applies to |
|-------|------|---------|------------|
| `selectTimeout` | `Duration` | `.seconds(30)` | `select`, `scalar`, `selectAll`, `execute` |
| `insertTimeout` | `Duration` | `.seconds(60)` | `insert`, `insertNativeBlock` |
| `pingTimeout` | `Duration` | `.seconds(5)` | `ping` |
| `streamTimeout` | `Duration` | `.seconds(300)` | `stream` (continuous reads) |

## Error handling

`ClickHouseError` is the single typed error enum surfaced by every
public operation. Adding a case is a SemVer-breaking change because
exhaustive `switch` statements downstream stop compiling — that is
intentional.

| Case | Fires when | Recovery |
|------|-----------|----------|
| `connectionFailed(reason:)` | Socket open, DNS lookup, or handshake refused. | Verify endpoint, credentials, server availability. The reconnect loop already retries transient open failures; this case fires only after the budget is exhausted on the first connect. |
| `socketIOFailed(errno:syscall:)` | An in-flight `send`/`recv` syscall returned `-1`. | The reconnect path opens a fresh socket; the caller's request is surfaced as failed. Retry the operation. |
| `unexpectedEOF(bytesExpected:)` | `recv` returned 0 mid-frame. The server closed the socket. | Reconnect occurs automatically on the next call; retry the operation. |
| `protocolError(stage:message:)` | Wire bytes violate the framing contract, or the result shape does not match the typed call (e.g. `scalar` against a multi-row result). | Application bug or schema drift. Inspect the `stage` for the layer (`select`, `insert.schema`, `wire`, ...) and the `message` for the violation. |
| `queryFailed(serverException:)` | Server returned a fully-decoded Exception packet. | Route on `serverException.code` for typed handling (e.g. `60` is "table does not exist"). Application or schema issue, not a transport problem. |
| `reconnectExhausted(attempts:)` | The per-connection reconnect budget hit zero. | Surface to the caller; the underlying endpoint is unreachable for longer than the policy allows. Consider widening the policy or failing over at the pool layer. |
| `endpointsExhausted(failures:)` | Pool tried every configured endpoint in one rotation and every connect attempt failed. | Inspect `failures` for per-host reasons. The cluster is unreachable; surface to the caller and let operators page on it. |
| `queryTimeout(elapsed:)` | The per-query `timeout:` fired before the server finished. | The local socket is shut down and the next call gets a fresh connection. The query may have partially executed server-side; for non-idempotent INSERTs, treat the outcome as unknown and rely on application-level idempotency. |

## Performance characteristics

On localhost loopback against ClickHouse 26.5, a 10M-row × 3-column
SELECT drains in roughly 130ms (about 2.4 GB/s sustained wire
throughput) and materialises into Swift values in roughly 2.8s. The
connection pool acquires an idle connection in single-digit
microseconds when one is available; opening a fresh connection
includes the Native handshake and is bounded by network round-trip
time. Per-block decode is bounded by the wire arrival rate; per-row
Codable decode adds a roughly constant ~700ns per field on top of the
columnar parse.

The transport is `POSIX socket → arena-backed wire decoder → optional
Codable bridge → async actor → optional pool`. Each layer's cost is
measurable in isolation against the layer below it. Numbers vary with
hardware, schema, and result-set shape; the bench harness below is
the reproducible source.

Full bench harness in `Benchmarks/Sources/ClickHouse/` and
`Benchmarks/run-real-workloads.sh`. The DocC performance-tuning
catalog documents per-layer cost and tuning guidance.

### Picking an overload

- **Codable** rows are the default. The encoder/decoder is optimised
  for the columnar wire format and is the fastest typed path.
- **Raw `[UInt8]`** SQL avoids one `String` allocation per call. Use
  it on the hottest paths.
- **`insertNativeBlock`** sends pre-encoded Native block bytes to the
  server with no client-side encoding work. Use it when you already
  have a columnar buffer (e.g. forwarded from another ClickHouse
  client) and want to skip the Codable encode step.
- **Stream / `DXMessageHandler`** delivers rows one at a time and
  applies back-pressure naturally via async iteration. Use it for
  large scans where memory matters.
- **`selectAll`** is the right choice when the result set is bounded
  and small enough to fit in memory; one allocation, one return.
- **View types** (`ClickHouseFixedStringView`, `ClickHouseMapView`,
  etc.) skip per-row copies. Use them when profiling shows
  allocation overhead dominating decode time.

## Documentation

The DocC catalog inside the module covers the full API:

- `Documentation.docc/DXClickHouse.md` — module overview and topic
  index.
- `Documentation.docc/Overloads.md` — every input-form overload with
  examples and cost notes.
- `Documentation.docc/Lifecycle.md` — connection, pool, and service
  lifecycles; fault-handling behaviour; reconnect timing.
- `Documentation.docc/PerformanceTuning.md` — per-mode bench
  numbers, layer cost breakdown, and tuning guidance.
