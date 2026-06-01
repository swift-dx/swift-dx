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
