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

import DXRedis
import Foundation
import NIOPosix

// Shared helpers for the live-server integration suites. Every suite is gated
// on REDIS_INTEGRATION_HOST so the tests are skipped automatically when no
// server is reachable. Run with:
//
//     REDIS_INTEGRATION_HOST=localhost swift test --filter DXRedisIntegration
//
// Optional env vars: REDIS_INTEGRATION_PORT (default 6379),
// REDIS_INTEGRATION_AUTH_PORT (default 6380),
// REDIS_INTEGRATION_AUTH_PASSWORD (default "swiftdx-secret").
enum RedisIntegration {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REDIS_INTEGRATION_HOST"] != nil
    }

    static var host: String {
        ProcessInfo.processInfo.environment["REDIS_INTEGRATION_HOST"] ?? "localhost"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["REDIS_INTEGRATION_PORT"] ?? "6379") ?? 6379
    }

    static var authPort: Int {
        Int(ProcessInfo.processInfo.environment["REDIS_INTEGRATION_AUTH_PORT"] ?? "6380") ?? 6380
    }

    static var authPassword: String {
        ProcessInfo.processInfo.environment["REDIS_INTEGRATION_AUTH_PASSWORD"] ?? "swiftdx-secret"
    }

    // Integration clients disable the resilience retry so tests are deterministic:
    // many of them issue non-idempotent commands (INCR, APPEND, GETDEL) and run in
    // parallel, where a retried transient blip would silently re-apply a command
    // and corrupt the assertion. Retry behaviour itself is covered by the unit
    // suite (RedisResilienceTests) against a closed port.
    static func makeClient(database: Int = 0, maxConnections: Int = 8) throws -> RedisClient {
        RedisClient(configuration: .init(
            endpoint: .init(host: host, port: port),
            database: try RedisDatabaseIndex(database),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            maxConnections: maxConnections,
            maxIdleConnections: maxConnections,
            resilience: .disabled
        ))
    }

    static func uniquePrefix() -> String {
        "dxr-test:\(UUID().uuidString)"
    }

    static func uniqueKey(_ suffix: String) -> RedisKey {
        RedisKey("\(uniquePrefix()):\(suffix)")
    }

    static func rawCommand(_ tokens: [String]) -> RedisCommand {
        RedisCommand(arguments: tokens.map { Array($0.utf8) })
    }

    static func setCommand(_ key: String, _ value: String) -> RedisCommand {
        RedisCommand(arguments: [Array("SET".utf8), Array(key.utf8), Array(value.utf8)])
    }
}
