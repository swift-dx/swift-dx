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

/// Entry point to the DXClickHouse client.
///
/// `ClickHouse` is a namespace, not a value you hold onto. Its job is to hand
/// you a ``ClickHouseClient`` — the actor that carries every operation. You
/// call `ClickHouse.connect(…)` once, then call methods on the client it
/// returns.
///
/// ## Long-lived application client
///
/// Open once at startup, hold it for the lifetime of the process, and share
/// the one instance across every request handler. ``ClickHouseClient`` is an
/// actor that serialises every wire round-trip through a private worker
/// queue, so concurrent callers from different async contexts share the
/// connection safely.
///
/// ```swift
/// let clickhouse = try await ClickHouse.connect(
///     host: "127.0.0.1",
///     port: 9000,
///     user: "default",
///     password: "",
///     database: "default"
/// )
/// let rowCount: UInt64 = try await clickhouse.scalar("SELECT count() FROM events", as: UInt64.self)
/// await clickhouse.close()
/// ```
///
/// ## Scoped usage (scripts, tests, one-off tools)
///
/// Connects, runs the body, then closes the client whether the body returns
/// or throws. This is not the per-request path of a long-running service —
/// it opens and closes a client each call.
///
/// ```swift
/// try await ClickHouse.withClient(
///     host: "127.0.0.1",
///     port: 9000,
///     user: "default",
///     password: "",
///     database: "default"
/// ) { clickhouse in
///     try await clickhouse.insert(into: "events", rows: batch)
/// }
/// ```
public enum ClickHouse {

    /// Opens a long-lived client connected to the named ClickHouse server.
    /// Hold the returned client for the application lifetime; call
    /// ``ClickHouseClient/close()`` to release the underlying socket.
    public static func connect(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default"
    ) async throws(ClickHouseError) -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    /// Connects, runs `body` with the client, then closes the client whether
    /// `body` returns or throws. For scripts, tests, and one-off tools — not
    /// the per-request path of a long-running service.
    public static func withClient<Result>(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        _ body: (ClickHouseClient) async throws -> Result
    ) async throws -> Result {
        let client = try await connect(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    /// Configuration-driven open. Same single-connection `ClickHouseClient`
    /// the ad-hoc host/port overload returns; the configuration vocabulary
    /// matches the long-running ``ClickHouseService`` entry point so a
    /// caller can switch from ad-hoc to service-managed without rewriting
    /// connection arguments.
    public static func connect(_ configuration: ClickHouseConfiguration) async throws(ClickHouseError) -> ClickHouseClient {
        try await ClickHouseClient(configuration: configuration)
    }

    /// Configuration-driven scoped helper. Connects, runs `body`, closes
    /// whether `body` returns or throws.
    public static func withClient<Result>(
        _ configuration: ClickHouseConfiguration,
        _ body: (ClickHouseClient) async throws -> Result
    ) async throws -> Result {
        let client = try await connect(configuration)
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}
