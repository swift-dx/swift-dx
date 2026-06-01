# SwiftDX

[![CI](https://github.com/swift-dx/swift-dx/actions/workflows/ci.yml/badge.svg)](https://github.com/swift-dx/swift-dx/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/swift-dx/swift-dx?include_prereleases&sort=semver&label=release)](https://github.com/swift-dx/swift-dx/releases)
[![Swift 6.3+](https://img.shields.io/badge/Swift-6.3%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20Linux-blue.svg)](#requirements)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

SwiftDX is a set of Swift libraries for the data layer of server-side applications.

Libraries are designed for predictable low-latency, high-throughput operation on the data path. Each library ships with a reproducible benchmark harness exercised on Ubuntu Linux under production-equivalent conditions. Performance regressions are tracked as bugs.

All direct dependencies are sourced from `github.com/apple/*` or `github.com/swift-server/*`. This bounds the supply-chain attack surface, ensures long-term institutional maintenance, and matches the trust posture enterprise consumers apply when auditing transitive dependencies. When functionality is only available in a third-party package, SwiftDX implements it inside `DXCore` rather than introducing the dependency.

> **Status: pre-1.0, evolving.** Public APIs may change between minor versions while the surface converges. Every breaking change is called out in the release notes and the commit footer (`BREAKING CHANGE:`). Pin to an exact version in production until SwiftDX reaches `1.0.0`.

## Libraries

| Library | Purpose |
|---------|---------|
| [`DXCore`](Sources/DXCore) | Shared foundation types. |
| [`DXJetStream`](Sources/DXJetStream) | NATS JetStream client. |
| [`DXClickHouse`](Sources/DXClickHouse) | ClickHouse Native protocol client. |
| [`DXRedis`](Sources/DXRedis) | Redis client. |
| [`DXPostgres`](Sources/DXPostgres) | PostgreSQL wire-protocol client (also YugabyteDB, CockroachDB). |
| [`DXSQLite`](Sources/DXSQLite) | Embedded SQLite client (vendored amalgamation, WAL). |
| [`DXJSONSchema`](Sources/DXJSONSchema) | JSON Schema Draft 2020-12 validator. |

## Installation

```swift
// Package.swift
dependencies: [
    // Pre-1.0: pin to a minor range so patch upgrades flow in but a
    // 0.2.0 release (which may introduce breaking changes) does not.
    .package(url: "https://github.com/swift-dx/swift-dx", .upToNextMinor(from: "0.1.0")),
    // For production deployments, prefer an exact pin until 1.0.0:
    //   .package(url: "https://github.com/swift-dx/swift-dx", exact: "0.1.0"),
],
targets: [
    .target(
        name: "MyService",
        dependencies: [
            .product(name: "DXJetStream", package: "swift-dx"),
        ]
    ),
]
```

```swift
import DXJetStream
```

## DXClickHouse

ClickHouse Native protocol client. Direct POSIX-socket transport (no
NIO, no event loop), typed Codable surface, multi-endpoint connection
pool with failover, built-in reconnect, per-query timeouts, and
`swift-service-lifecycle` integration. Zero-allocation view types
expose the wire buffer directly for the hot path; the Codable surface
covers the ergonomic path.

```swift
import DXClickHouse

let client = try await ClickHouse.connect(.init(endpoints: [.init(host: "ch", port: 9000)]))
let users: [User] = try await client.selectAll("SELECT id, name FROM users", as: User.self)
await client.close()
```

Full overload reference, configuration fields, error cases, and usage
patterns are in [Sources/DXClickHouse/README.md](Sources/DXClickHouse/README.md).
The DocC catalog inside the module has the per-mode benchmark numbers
and a lifecycle/performance-tuning guide.

## DXRedis

Pure-Swift Redis 8 client built on SwiftNIO. A `RedisClient` owns a
bounded pool of pipelining RESP2 connections; one shared client serves
the whole process, concurrent callers run in parallel up to the pool
size, and a single caller can pile thousands of commands onto one
connection. Absent values are a named `Lookup` case rather than `nil`,
every public throwing function uses typed `throws(RedisError)`, and
payloads accept `[UInt8]`, `ByteBuffer`, `String`, and `Codable`
(JSON). Per-request timeouts, transient-failure retries, and
background reconnection are built in.

```swift
import DXRedis

let redis = try await Redis.connect(
    RedisConfiguration(endpoint: RedisEndpoint(host: "127.0.0.1", port: 6379))
)
try await redis.set("user:42:name", to: "Ada")
let name = try await redis.getString("user:42:name")
```

Configuration fields, the full command surface, error cases, and the
ServiceLifecycle integration are documented in
[Sources/DXRedis/README.md](Sources/DXRedis/README.md).

## DXPostgres

Pure-Swift PostgreSQL client implementing the v3 wire protocol directly
over SwiftNIO — no `libpq` and no system library to link. A
`PostgresClient` owns a bounded connection pool and speaks SCRAM-SHA-256,
MD5, and cleartext authentication with TLS. It runs simple and
parameterized queries, streams large result sets in bounded memory, and
supports transactions and `COPY` bulk load; a single query transparently
retries transient failures and reconnects. Decoding covers the common
scalar and array types plus `numeric`, JSON, money, time, interval, inet,
the built-in geometric types, and PostGIS geometry, in both binary and
text format. SQL NULL is a named value, never an optional, and every
public throwing function uses typed `throws(PostgresError)`. The same
wire protocol serves YugabyteDB and CockroachDB. Structured logging,
`swift-distributed-tracing` spans, and `swift-metrics` instruments are
built in and flow automatically once the application bootstraps a backend.

```swift
import DXPostgres

try await Postgres.withClient(
    PostgresConfiguration(
        endpoint: PostgresEndpoint(host: "localhost"),
        credentials: .password(username: "postgres", password: "secret"),
        database: PostgresDatabaseName("appdb")
    )
) { postgres in
    let result = try await postgres.query("SELECT id, name FROM accounts WHERE id = $1", binding: [42])
    for row in result.rows {
        print(try row.decode(Int.self, named: "id"), try row.decode(String.self, named: "name"))
    }
}
```

Authentication and TLS options, the full type and overload surface, the
observability instruments, resilience tuning, and the ServiceLifecycle
integration are documented in
[Sources/DXPostgres/README.md](Sources/DXPostgres/README.md).

## DXSQLite

Embedded SQLite client over a vendored SQLite amalgamation — no system
library to link and no version skew with the host. A `SQLiteDatabase`
runs SQLite in WAL mode with one writer and many concurrent readers over
a thread pool; reads, writes, and transactions are submitted as closures
that run off the calling thread. Rows decode into `Codable` types or are
read by column, large result sets stream lazily, and the database can be
bound ambiently so deep code reaches it without being passed it. Update,
commit, and rollback hooks, custom functions and collations, an
authorizer, blob streaming, and session changesets are exposed; every
public throwing function uses typed `throws(SQLiteError)`.

```swift
import DXSQLite

struct Item: Codable, Sendable { let id: Int; let name: String }

let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: "app.sqlite")))

try await database.transaction { writer in
    try writer.execute("CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    _ = try writer.mutate("INSERT INTO item (id, name) VALUES (?, ?)", parameters: [1, "Keyboard"])
}

let items = try await database.read { reader in
    try reader.query("SELECT id, name FROM item ORDER BY id", as: Item.self)
}
await database.close()
```

A runnable tour of the reader/writer surface, streaming, ambient binding,
hooks, custom functions, and blob and changeset APIs is in
[Examples/Sources/SQLite/QuickStart](Examples/Sources/SQLite/QuickStart/main.swift).

## DXJSONSchema

JSON Schema Draft 2020-12 validator. Compile a schema once, then validate
many instances against it. The instance parser is a Foundation-free byte
parser; strings are sliced from the source buffer rather than copied. A
hot-swappable, type-grouped registry handles many schemas with atomic bulk
updates and parallel, ID-tagged batch verification. Passes 100% of the
mainline Draft 2020-12 official test suite.

```swift
import DXJSONSchema

let schema = try JSONSchema.compile(#"{"type":"object","required":["id"],"properties":{"id":{"type":"integer"}}}"#)
let result = schema.validate(#"{"id": 42}"#)
if !result.isValid {
    for violation in result.violations { print(violation.instanceLocation, violation.message) }
}
```

The usage forms (`[UInt8]`/`String`/`ByteBuffer`/`Encodable`), the registry
and batch-verify API, error cases, the performance-testing harness, and the
memory characteristics under sustained load are documented in
[Sources/DXJSONSchema/README.md](Sources/DXJSONSchema/README.md).

## Requirements

- Swift 6.3+
- macOS 26+ or Linux (Ubuntu, `swift:6.3` Docker image)

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
