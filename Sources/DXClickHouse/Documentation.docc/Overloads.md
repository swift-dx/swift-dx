# Overloads

Every operation on ``ClickHouseClient`` that accepts SQL or row data
is offered in multiple input forms. Pick the one that reads cleanly at
the call site; the cost difference between forms is bounded and
documented.

## Why every operation has several signatures

`DXClickHouse` follows the same overload pattern used across
SwiftDX: there is one canonical performance primitive per operation,
and every other form converts to that primitive before delegating.
Callers can mix and match shapes per call site without paying for an
abstraction they do not use.

The performance primitive depends on direction:

- **For reads (SELECT, scalar, execute, ping):** the primitive is the
  raw SQL bytes form (`[UInt8]`) when the call originates from a
  pre-encoded buffer, or the `String` form when the caller has a Swift
  string in hand. The two forms differ only by a UTF-8 decode hop.
- **For writes (INSERT):** the primitive is the columnar Codable form
  over `[Row]`. The encoder produces a single Native data packet,
  validates the destination schema against the encoded columns, and
  ships the packet in one round-trip.

The library deliberately does NOT offer a NIO `ByteBuffer` overload on
the public surface. `DXClickHouse` is built precisely to avoid
taking a dependency on NIO; offering one convenience overload that
required `NIOCore` would defeat that. Callers that hold a `ByteBuffer`
should copy its contents into `[UInt8]` at the call site.

## Read operations

### `execute`

Drains all blocks returned by the server and ignores the rows. Use for
DDL (`CREATE`, `DROP`, `ALTER`), TRUNCATE, OPTIMIZE, and any other
statement whose result you do not need to consume.

```swift
try await client.execute("CREATE TABLE events (id UInt64, payload String) ENGINE = MergeTree ORDER BY id")
try await client.execute(sqlBytes)                  // pre-encoded SQL
client.execute("OPTIMIZE TABLE events FINAL") { result in
    if case .failure(let error) = result { logger.warning("optimize failed: \(error)") }
}
```

### `ping`

Round-trips Ping → Pong with the server. The connection pool's
preflight check uses this internally; consumers can call it directly
for liveness probing.

```swift
try await client.ping()
client.ping { result in /* … */ }
```

### `scalar(_:as:)`

Runs a SELECT expected to return exactly one row + one column, decodes
the cell into `T`, and returns it. Throws if the result shape is not
1×1.

```swift
let count: UInt64 = try await client.scalar(
    "SELECT count() FROM events WHERE event_date = today()",
    as: UInt64.self
)
let countBytes: UInt64 = try await client.scalar(preEncodedSQL, as: UInt64.self)
client.scalar("SELECT version()", as: String.self) { result in
    switch result {
    case .success(let version): logger.info("server version: \(version)")
    case .failure(let error):   logger.error("scalar failed: \(error)")
    }
}
```

### `select(_:as:)` and `selectAll(_:as:)`

`select` returns an `AsyncThrowingStream` that yields one decoded `T`
per result row. `selectAll` awaits the entire stream and returns an
`[T]`. Choose `select` when memory pressure matters and the result set
is large; choose `selectAll` when the caller wants a finite array and
the result is bounded.

Both shapes accept optional ``ClickHouseQuerySettings`` and
``ClickHouseQueryParameters``.

```swift
for try await event in client.select("SELECT id, payload FROM events ORDER BY id", as: Event.self) {
    handle(event)
}

let recent = try await client.selectAll(
    "SELECT id, payload FROM events WHERE event_date = today()",
    as: Event.self,
    settings: ClickHouseQuerySettings([
        ClickHouseQuerySetting(name: "max_threads", value: "4"),
    ]),
    parameters: .empty
)

client.select("SELECT id FROM events", as: UInt64.self) { result in
    if case .success(let ids) = result { /* … */ }
}
```

For continuous consumption with explicit per-row handling, use
`stream(_:as:handler:)`. The handler receives one element at a time
and a terminal `receive(error:)` call if the stream throws.

```swift
struct EventSink: DXMessageHandler {
    typealias Message = Event
    typealias Failure = ClickHouseError
    func receive(_ message: Event) async { /* … */ }
    func receive(error: ClickHouseError) async { /* … */ }
}

let task = client.stream("SELECT id, payload FROM events", as: Event.self, handler: EventSink())
// task can be cancelled to tear down the underlying stream early.
```

## Write operations

### `insert(into:rows:)`

The Codable INSERT path. The encoder walks each row's `Encodable`
representation, builds one column buffer per field, and emits a single
Native data packet. The destination schema is validated against the
encoded column set before the body bytes are sent.

The primitive accepts `[T]`. Convenience overloads exist for `Sequence`
(any element type that is `Encodable & Sendable`) and `AsyncSequence`
(streamed row source, fully materialised before encoding).

```swift
let summary = try await client.insert(into: "events", rows: [event1, event2, event3])
print("server wrote \(summary.writtenRows) rows in \(summary.blocksSent) block(s)")

// Sequence: any Encodable & Sendable element type.
try await client.insert(into: "events", rows: orderedSet)

// AsyncSequence: rows arrive over time, collected before send.
try await client.insert(into: "events", rows: networkStream)

// Callback form.
client.insert(into: "events", rows: [event1, event2]) { result in
    if case .failure(let error) = result { logger.error("insert failed: \(error)") }
}
```

### `insertNativeBlock(into:columnList:nativeBlockBytes:)`

Escape hatch for callers that have already encoded a Native-format
block elsewhere (for example, columnar data assembled by a
non-Codable pipeline). The library ships the bytes through the INSERT
handshake without inspecting them; the server validates that the bytes
match the destination schema.

```swift
let blockBytes = myExternalEncoder.encodeNativeBlock(/* … */)
let summary = try await client.insertNativeBlock(
    into: "events",
    columnList: "(id, payload)",
    nativeBlockBytes: blockBytes
)
```

The returned `ClickHouseInsertSummary.rowsSent` is zero on this
path because the library never counted the rows; `writtenRows` /
`writtenBytes` come from the server's last Progress packet and are
authoritative.

## Picking the right shape

| Call site shape | Use |
|---|---|
| Single statement, no result | `execute(_:)` |
| Single value, known type | `scalar(_:as:)` |
| Bounded result set, fully in memory | `selectAll(_:as:)` |
| Large or unbounded result set | `select(_:as:)` (AsyncThrowingStream) |
| Push-style per-row consumption | `stream(_:as:handler:)` |
| Closure-based result delivery | callback overloads |
| Array of rows | `insert(into:rows:)` (primitive) |
| Sequence of rows | `insert(into:rows:)` (Sequence overload) |
| Async producer of rows | `insert(into:rows:)` (AsyncSequence overload) |
| Pre-encoded Native block | `insertNativeBlock(…)` |

The cost of each non-primitive overload is exactly one conversion
hop: a UTF-8 decode for the SQL-bytes form, an `Array(seq)` for
`Sequence`, a `for try await` collect for `AsyncSequence`, a
`Task { }` wrap for the callback form. None of these shapes adds an
unbounded cost; they exist so consumers do not need to write the same
adapter at every call site.
