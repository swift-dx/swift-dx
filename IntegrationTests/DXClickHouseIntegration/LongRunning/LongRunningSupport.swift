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

import DXClickHouse
import Foundation

// Shared scaffolding for the LongRunning suites. Every test in this
// folder is gated by CH_LONG_RUNNING=1 so a normal `swift test` run
// skips them. When enabled they take minutes to hours; their job is to
// catch slow leaks, P99 drift, and steady-state degradation that the
// per-call integration tests cannot see.
enum LongRunningSupport {

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["CH_LONG_RUNNING"] == "1"
    }

    static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouse.connect(
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    static func makePool(maxConnections: Int) async throws -> ClickHouseConnectionPool {
        try await ClickHouseConnectionPool(
            host: host, port: port,
            user: user, password: password, database: database,
            minConnections: 1,
            maxConnections: maxConnections,
            acquireTimeout: .seconds(30)
        )
    }

    static func uniqueTable(prefix: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "long_running_\(prefix)_\(suffix)"
    }

    // P99 helper sized identically to the stability suites so a drift
    // calculation here matches what the soak reporters already compute.
    static func percentileMicroseconds(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
        if sortedSamples.isEmpty { return 0 }
        let lastIndex = sortedSamples.count - 1
        let position = Int((Double(lastIndex) * fraction).rounded())
        return sortedSamples[min(max(position, 0), lastIndex)]
    }

    static func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
        let duration = ContinuousClock.now - start
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
