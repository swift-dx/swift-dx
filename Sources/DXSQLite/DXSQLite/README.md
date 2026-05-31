<!--
===----------------------------------------------------------------------===
This source file is part of the SwiftDX open source project

Copyright (c) 2026 SwiftDX Contributors
Licensed under Apache License v2.0. See LICENSE for license information.

SPDX-License-Identifier: Apache-2.0
===----------------------------------------------------------------------===
-->

# DXSQLite

Swift native SQLite client. Vendored SQLite 3.53.1 amalgamation, WAL with one
writer and a pool of concurrent readers, blocking calls run off the
cooperative executor on a thread pool.

## Quick start

```swift
import DXSQLite

let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: "app.sqlite")))

try await database.write { writer in
    try writer.execute("CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    _ = try writer.mutate("INSERT INTO item(name) VALUES (?)", parameters: ["Ada"])
}

let names = try await database.read { reader in
    try reader.query("SELECT name FROM item ORDER BY id")
}

await database.close()
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
            .product(name: "DXSQLite", package: "swift-dx"),
        ]
    ),
]
```

## Core concepts

### Vendored engine

`DXSQLite` compiles the public-domain SQLite 3.53.1 amalgamation into the
package, so macOS and Linux run the exact same engine independent of the
system `libsqlite3`. Full-text search (FTS5), R*Tree, JSON, math functions,
the session extension, and snapshots are all compiled in.

### One writer, many readers

SQLite serializes writes to a single connection. `DXSQLite` owns exactly one
writer connection and a bounded pool of read-only connections. Under WAL,
readers run concurrently with each other and with the writer. `write { }`
runs on the writer; `read { }` checks out a reader and waits for a free one
when all are busy. Blocking SQLite calls execute on a `NIOThreadPool`, so they
never block Swift's cooperative threads.

### Transactions

`transaction { }` wraps the body in `BEGIN IMMEDIATE` / `COMMIT` and rolls back
if the body throws — including an error of your own type:

```swift
try await database.transaction { writer in
    _ = try writer.mutate("UPDATE account SET balance = balance - 10 WHERE id = ?", parameters: [1])
    _ = try writer.mutate("UPDATE account SET balance = balance + 10 WHERE id = ?", parameters: [2])
}
```

### Typed values and decoding

Columns read out as `SQLiteValue` (`.null` / `.integer` / `.real` / `.text` /
`.blob`). Pull typed values by name, or decode a whole row into a `Decodable`:

```swift
struct Item: Decodable { let id: Int; let name: String }

let items = try await database.read { reader in
    try reader.query("SELECT id, name FROM item ORDER BY id", as: Item.self)
}
```

### Streaming

`readStream` yields rows lazily as an `AsyncThrowingStream`, holding a reader
for the stream's lifetime:

```swift
for try await row in database.readStream("SELECT id FROM item ORDER BY id") {
    let id = try row.integer(named: "id")
}
```

### Service lifecycle

`SQLiteDatabase` conforms to ServiceLifecycle's `Service`, so it runs inside a
`ServiceGroup` and closes its pools on graceful shutdown. Bind a database for a
scope with `SQLite.withCurrent(_:_:)` and read it back with `SQLite.current()`
from code that was never handed the database.

### Tuning and durability

`SQLiteTuning` sets the per-connection storage knobs, applied to the writer and
every reader. The defaults mirror SQLite's own; override them for stricter
durability or a larger working set:

```swift
let database = try await SQLite.connect(SQLiteConfiguration(
    location: .file(path: "app.sqlite"),
    tuning: SQLiteTuning(synchronous: .full, cacheSizeKibibytes: 65_536)
))
```

`synchronous: .full` fsyncs the write-ahead log on every commit (durable across
power loss); the default `.normal` fsyncs at checkpoints (crash-safe and
faster). `cacheSizeKibibytes`, `mmapSizeBytes`, and `pageSize` size the page
cache, memory-mapped I/O, and — on a freshly created database — the page size.

### Authorization

Install a compile-time authorizer to constrain what statements may do — reject
writes, redact a column, or block `ATTACH`. The policy runs on every connection
the database opens:

```swift
let readOnly = SQLiteAuthorizationPolicy.custom { action in
    switch action {
    case .insert, .update, .delete: return .deny
    case .read(_, let column) where column == "secret": return .ignore
    default: return .allow
    }
}
let database = try await SQLite.connect(SQLiteConfiguration(
    location: .file(path: "app.sqlite"),
    authorization: readOnly
))
```

`.deny` fails the whole statement; `.ignore` neutralizes a single action — a
denied column read returns NULL instead of its value.

### Storage backend

`DXSQLite` uses the platform's default SQLite VFS (`unix` on Linux and macOS)
for all file I/O, locking, and fsync. A custom VFS layer — for encryption at
rest, compression, remote storage, or fault injection — is intentionally out of
scope for the core client; such a backend would be added as a separate, opt-in
component if a concrete need arises.
