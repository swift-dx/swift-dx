# DXRedis

A pure-Swift client for Redis 8, built on SwiftNIO. It targets the data path of
server-side applications: predictable low-latency, high-throughput key/value
access with a Swift 6 concurrency surface.

> **Status: pre-1.0, evolving.** Public APIs may change between minor versions.
> Pin to an exact version in production until SwiftDX reaches `1.0.0`.

## Overview

- **Pure Swift.** RESP2 protocol implemented over SwiftNIO.
- **Pooled and pipelining.** A `RedisClient` owns a bounded pool of pipelining
  connections. One shared client serves the whole process; concurrent callers run
  in parallel up to the pool size, and a single caller can pile thousands of
  commands onto one connection.
- **Swift-native API.** Absent values are a named `Lookup` case, never `nil`.
  Every public throwing function uses typed `throws(RedisError)`. Payloads accept
  `[UInt8]`, `ByteBuffer`, `String`, and `Codable` (JSON).
- **Transparent resilience.** A per-request timeout, transient-failure retries,
  and background reconnection are built in, so callers do not handle connection
  state.

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
            .product(name: "DXRedis", package: "swift-dx"),
        ]
    ),
]
```

```swift
import DXRedis
```

## Getting started

The entry point is the `Redis` namespace. Operations live on the `RedisClient`
it returns.

### Long-lived application client

Open once at startup and share the one instance for the process lifetime.
`RedisClient` conforms to ServiceLifecycle's `Service`, so it runs inside a
`ServiceGroup` and shuts its pool down on graceful termination.

```swift
let redis = try await Redis.connect(
    RedisConfiguration(endpoint: RedisEndpoint(host: "127.0.0.1", port: 6379))
)

try await redis.set("user:42:name", to: "Ada")
let name = try await redis.getString("user:42:name")   // Lookup<String>
let visits = try await redis.send(RedisCommand("INCR", "user:42:visits"))
```

Under a `ServiceGroup`, construct the client and let the group drive its
lifecycle; do not call `connect` in this path:

```swift
let redis = RedisClient(configuration: configuration)
let group = ServiceGroup(services: [redis, myServer], logger: logger)
try await group.run()
```

### Scoped usage (scripts, tests, one-off tools)

```swift
try await Redis.withClient(configuration) { redis in
    try await redis.set("k", to: "v")
}
```

### Ambient access

Bind one client for a scope and read it back from code that was not handed it,
without threading it through every signature. Reading before anything is bound
throws `RedisError.noCurrentClient`.

```swift
try await Redis.withCurrent(sharedRedis) {
    try await handleRequest()
}

func handleRequest() async throws {
    let redis = try Redis.current()
    _ = try await redis.send(RedisCommand("INCR", "requests:handled"))
}
```

## Capabilities

A client's operations are grouped into capability protocols, which also serve as
the menu of what the client does. Depend on one directly (e.g. `some RedisValues`)
when a type needs only a narrow slice.

| Protocol | Covers |
|----------|--------|
| `RedisValues` | `GET`/`SET`, batch and pipelined multi-key, conditional writes, JSON |
| `RedisExpiry` | time to live, expire, persist |
| `RedisScripting` | raw commands, pipelines, Lua (`EVAL`/`EVALSHA`), array replies |
| `RedisLocking` | advisory distributed locks |
| `RedisAdmin` | database selection, flush, pool warm-up and stats, ping, shutdown |

## Working with values

### Input forms

`[UInt8]` is the performance primitive and the universal escape hatch; the other
forms convert to it.

```swift
try await redis.set("k", to: [0x76, 0x76])                 // [UInt8]
try await redis.set("k", to: byteBuffer)                   // NIO ByteBuffer
try await redis.set("k", to: "hello")                      // String (UTF-8)
try await redis.set("k", toJSON: order)                    // Encodable, JSON-encoded
```

### Read forms

Reads return a `Lookup<T>` — `.found(value)` when the key exists, `.notFound`
when it does not. There is no optional to unwrap.

```swift
let raw: Lookup<ByteBuffer> = try await redis.get("k")     // zero-copy view
let bytes: Lookup<[UInt8]>  = try await redis.getBytes("k")
let text: Lookup<String>    = try await redis.getString("k")
let order: Lookup<Order>    = try await redis.get("k", asJSON: Order.self)
```

### Many keys at once

```swift
try await redis.set([RedisKeyValuePair(key: "a", value: "1"), RedisKeyValuePair(key: "b", value: "2")])  // MSET, atomic
let values = try await redis.get(["a", "b", "c"])          // MGET, one atomic array reply
try await redis.setPipelined(pairs)                        // many SETs, pipelined
let many = try await redis.getPipelined(keys)              // many GETs, pipelined
```

### Arbitrary commands and Lua

Any command reaches the server through `send` (scalar reply) and `sendArray`
(array reply). This covers everything without a typed method, including
`EVAL`/`EVALSHA`:

```swift
let n = try await redis.send(RedisCommand("EVAL", "return redis.call('INCR', KEYS[1])", "1", "counter")).integerValue()
let rows = try await redis.sendArray(RedisCommand("LRANGE", "list", "0", "-1"))   // lazy RedisReplyArray
let digest = try await redis.send(RedisCommand("SCRIPT", "LOAD", script)).stringValue()
```

`RedisReplyArray` is lazy: elements are materialized on access (`count`,
`stringLookup(at:)`, `integerValue(at:)`, `nestedArray(at:)`), so partial and
containment reads do not pay for the whole reply.

## Resilience

The client absorbs transient trouble so callers see typed results, not connection
state. Configured via `RedisResilience` on `RedisConfiguration`:

- **Per-request timeout** (default 10s) bounds the whole operation — acquiring a
  connection, waiting out a reconnect, and the command round-trip. On expiry the
  operation throws `RedisError.timedOut`. The client never reports a success it
  did not receive from the server.
- **Transient-failure retries** within the timeout window reconnect and retry a
  dropped connection or a momentarily full pool. A timeout is *terminal* (its
  outcome is unknown) and is never retried; for non-idempotent command sequences
  use `RedisResilience.disabled` to turn retries off entirely.
- **Background reconnection** is paced (20 ms → 1 s backoff), bounded by the pool
  size, and coordinated through the pool, so an outage neither spins the CPU nor
  stampedes the server.
- **Boot tolerance.** Under a `ServiceGroup`, an unreachable server at startup is
  logged (via `swift-log`) and the service starts anyway — identical to a mid-life
  outage. The process does not fail to boot because Redis is briefly down.

## Performance

Benchmarked against the reference C client (`hiredis`) on the same localhost
Redis 8.8.0, 1,000,000 distinct keys, 16-byte values, repeated-run medians
(`swift build -c release`).

| Path | DXRedis / hiredis | Result |
|------|-------------------|--------|
| Pipelined `SET` (`setPipelined`) | **1.64x** | faster |
| Pipelined `GET` (`getPipelined`) | **1.60x** | faster |
| `MSET` | **1.05x** | faster |
| `MGET` (one atomic array reply) | 0.81x | hiredis faster (materialization floor) |
| Array read-all (`sendArray`) | ~0.9x | ~parity (decode-bound floor) |
| Single-op latency | ~1.55x | hiredis faster (per-op async + RTT floor) |

### Choosing the fastest modality

- **Throughput: pipeline.** `setPipelined` / `getPipelined` and `pipeline([...])`
  batch many commands into one network round-trip and one decode pass; these are
  the fastest paths and beat hiredis. Reach for them whenever you have more than a
  few keys.
- **Bulk by-key reads: `getPipelined` beats `MGET`.** `MGET` returns one atomic
  array and sits at the per-element materialization floor (0.81x). If you do not
  need atomicity across the keys, `getPipelined` is faster than hiredis.
- **Array reads: `sendArray`.** Its lazy `RedisReplyArray` defers per-element
  materialization, so partial/containment/paginated reads beat hiredis; strict
  read-all is ~parity.
- **Payload form: `[UInt8]`.** The bytes path goes straight to the wire framer.
  `ByteBuffer`, `String`, and `Codable` add only their own conversion cost.
- **Single operations** (one `get`/`set` at a time) are correct and convenient but
  carry a per-operation async cost over the localhost round-trip floor (~1.55x
  hiredis on p50 latency). For high request rates, batch or pipeline.

## Limitations

- **RESP2 only.** RESP3 types and client-side caching (`CLIENT TRACKING`
  invalidation) are not implemented. All RESP2 reply shapes — including every
  shape `EVAL` returns — decode.
- **Storage-focused.** There is no high-level pub/sub or streams *consumer* API.
  The underlying commands are reachable through `send`/`sendArray`, but the
  ergonomic surface targets key/value, scripting, locking, and administration.
- **Single endpoint or static endpoint list.** There is no Redis Cluster slot
  routing; an endpoint list provides connect-time failover, not sharding.
- **Lua via the raw command path.** `EVAL`/`EVALSHA` work through
  `send`/`sendArray`; there is no typed `eval(script:keys:arguments:)` convenience
  yet.
- **At-least-once on retried non-idempotent commands.** If a connection drops
  after a command is written but before its reply arrives, a retry may re-apply
  it. Idempotent commands are unaffected; use `RedisResilience.disabled` for
  non-idempotent sequences.

## Testing

- **Unit tests** cover the protocol codec, pool, configuration, resilience policy,
  and ambient context.
- **Public-API tests** import the module without `@testable`, exercising only what
  an external consumer can reach.
- **Integration tests** run against a live server, gated on the
  `REDIS_INTEGRATION_HOST` environment variable so they are skipped when no server
  is reachable. They prove every storage command family, all `EVAL` reply shapes,
  the request timeout, reconnection, and boot tolerance against real Redis 8.

```sh
# Unit tests only (no server needed):
swift test

# With a live server. Integration tests share one Redis instance, so run them
# serially:
REDIS_INTEGRATION_HOST=127.0.0.1 swift test --no-parallel
```

Mechanical style and safety rules (no optionals, typed throws, file headers,
complexity bounds) are enforced by the `Integrity` build plugin when building with
`SWIFTDX_INTEGRITY=1`.

## Resource and leak audit

Beyond code review, the client is audited for memory, descriptor, and thread
leaks under sustained concurrent load. A harness drives one shared client with
hundreds of concurrent tasks running a randomized mix of reads, writes,
pipelines, array replies, scripts, locks, and induced timeouts, while four
independent tools observe it from different angles:

| Check | Tool | Looks for | Result |
|-------|------|-----------|--------|
| Sustained load | resident-memory / descriptor / thread sampling | growth that never plateaus | RSS and descriptor counts plateau under load and fall back on shutdown |
| Allocation profile | heaptrack | per-operation heap growth | peak bounded; retained set fixed, not proportional to operations |
| Reachability | LeakSanitizer | allocations unreachable at exit | no leak originating in client code |
| Concurrency | ThreadSanitizer | data races | none reported |

Across millions of operations, resident memory and descriptor and thread counts
stay bounded and are released when the client shuts down — the signature of no
leak — and the concurrency primitives run race-free.

## Requirements

- Swift 6.3+
- macOS 26+ or Linux (Ubuntu, `swift:6.3` Docker image)

## License

Apache 2.0. See the repository [LICENSE](../../LICENSE) and [NOTICE](../../NOTICE).
