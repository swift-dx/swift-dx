//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Entry point to the DXRedis client.
///
/// `Redis` is a namespace, not a value you hold onto. Its job is to hand you a
/// ``RedisClient`` — the object that carries every operation. You call
/// `Redis.connect(…)` once, then call methods on the client it returns.
///
/// ## Capabilities
///
/// A client's operations are grouped into capability protocols, which double as
/// the menu of what the client can do. Depend on one directly (`some RedisValues`)
/// when a type needs only a narrow slice:
///
/// - ``RedisValues`` — get and set, batch and pipelined multi-key, conditional writes, JSON
/// - ``RedisExpiry`` — time to live, expire, persist
/// - ``RedisScripting`` — raw commands, pipelines, Lua (`EVAL`), and array replies
/// - ``RedisLocking`` — advisory distributed locks
/// - ``RedisAdmin`` — database selection, flush, pool warm-up and stats, ping, shutdown
///
/// There are three ways in, for three situations.
///
/// ## Long-lived application client
///
/// Open once at startup, hold it for the lifetime of the process, and share the
/// one instance across every request handler. ``RedisClient`` is `Sendable` and
/// backed by a pool of pipelining connections, so concurrent callers are safe
/// and fast on a single shared instance. It conforms to ServiceLifecycle's
/// `Service`, so it can run inside a `ServiceGroup` and tear the pool down on
/// graceful shutdown.
///
/// ```swift
/// let redis = try await Redis.connect(configuration)
/// try await redis.set("user:42:name", to: "Ada")
/// let name = try await redis.getString("user:42:name")
/// let visits = try await redis.send(RedisCommand("INCR", "user:42:visits"))
/// ```
///
/// ## Scoped usage (scripts, tests, one-off tools)
///
/// Connects, runs the body, then shuts the client down whether the body returns
/// or throws. This is not the per-request path of a long-running service — it
/// opens and closes a client each call.
///
/// ```swift
/// try await Redis.withClient(configuration) { redis in
///     try await redis.set("k", to: "v")
/// }
/// ```
///
/// ## Ambient access
///
/// Bind one client for a scope with ``withCurrent(_:_:)``, then read it back
/// with ``current()`` from code deep in the call tree that was never handed the
/// client — without threading it through every function signature. You bind in
/// one place and read in another; you would never do both side by side. Reading
/// outside any binding throws ``RedisError/noCurrentClient`` rather than
/// returning a null or trapping.
///
/// ```swift
/// // Bind once at a boundary, e.g. the start of handling an inbound request:
/// try await Redis.withCurrent(sharedRedis) {
///     try await handleRequest()            // handleRequest is not passed the client
/// }
///
/// // ...elsewhere, inside code that never received the client:
/// func handleRequest() async throws {
///     let redis = try Redis.current()      // pulled from the binding above
///     _ = try await redis.send(RedisCommand("INCR", "requests:handled"))
/// }
/// ```
///
/// Ambient access is a convenience, not the only way in, and it is the trickiest
/// to follow: passing the client explicitly, or reading it from a web
/// framework's request context, are equally valid and easier to test.
public enum Redis {

    enum Ambient: Sendable {

        case unbound
        case bound(RedisClient)
    }

    @TaskLocal static var ambient: Ambient = .unbound

    /// Opens a long-lived client and warms one connection so the first
    /// operation does not pay connection setup. Hold the returned client for the
    /// application lifetime; call ``RedisClient/shutdown()``, or run it as a
    /// ServiceLifecycle `Service`, to release the pool.
    public static func connect(_ configuration: RedisConfiguration) async throws(RedisError) -> RedisClient {
        let client = RedisClient(configuration: configuration)
        do {
            try await client.warmUp(connections: 1)
            return client
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// Connects, runs `body` with the client, then shuts the client down whether
    /// `body` returns or throws. For scripts, tests, and one-off tools — not the
    /// per-request path of a long-running service.
    public static func withClient<Result>(_ configuration: RedisConfiguration, _ body: (RedisClient) async throws -> Result) async throws -> Result {
        let client = try await connect(configuration)
        do {
            let result = try await body(client)
            await client.shutdown()
            return result
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// Binds `client` as the ambient client for the duration of `body`. Any code
    /// in the same structured-task tree reads it back with ``current()``. The
    /// binding propagates to child tasks and task groups, but not across
    /// `Task.detached`, so bind at a scope that encloses the work.
    public static func withCurrent<Result>(_ client: RedisClient, _ body: () async throws -> Result) async rethrows -> Result {
        try await $ambient.withValue(.bound(client)) {
            try await body()
        }
    }

    /// Returns the ambient client bound by an enclosing ``withCurrent(_:_:)``.
    /// Throws ``RedisError/noCurrentClient`` when no client is bound in the
    /// current task tree.
    public static func current() throws(RedisError) -> RedisClient {
        guard case .bound(let client) = ambient else {
            throw RedisError.noCurrentClient
        }
        return client
    }
}
