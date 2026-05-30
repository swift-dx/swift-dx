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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOPosix

// Shared scaffolding for the production-scale load tests in this
// directory. Each load test exercises one of the Swift-wins / parity
// modes from the Swift-vs-C++ benchmark comparison at 1M+ rows or
// 1000+ concurrent operations and asserts four invariants:
//
//   1. Total throughput stays within 80% of the bench-measured peak
//      so a sneak regression on the hot path fails this test.
//   2. P99 latency sits under a sensible per-operation ceiling.
//   3. Process resident-set-size grows by less than 100 MB across
//      the run (skip on platforms where ProcessRSS returns 0).
//   4. The connection pool never reports a saturated waiter queue
//      (no pool exhaustion).
//
// The thresholds are sized for the localhost Docker-loop CI runner.
// They are intentionally generous on the upper bound (90+ MB RSS,
// 2x the bench latency) so cold-cache and allocator behaviour does
// not flake the suite, while still catching order-of-magnitude
// regressions on either axis.
enum LoadTestSupport {

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
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test"
    }

    // Hard ceiling on RSS growth during a single load test run. The
    // streaming insert/select paths must hold one block at a time;
    // any retention across blocks would push RSS past this bound.
    static let maximumResidentSetGrowthBytes: Int64 = 100 * 1024 * 1024

    static func uniqueTable(_ kind: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "\(database).load_\(kind)_\(suffix)"
    }

    static func makeConfiguration(
        eventLoopGroup: EventLoopGroup,
        maxConnections: Int
    ) -> ClickHouseClient.Configuration {
        .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections,
            maxIdleConnections: maxConnections,
            eventLoopGroup: eventLoopGroup
        )
    }

    static func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
        let duration = ContinuousClock.now - start
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }

    static func percentile(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
        if sortedSamples.isEmpty { return 0 }
        let lastIndex = sortedSamples.count - 1
        let position = Int((Double(lastIndex) * fraction).rounded())
        return sortedSamples[min(max(position, 0), lastIndex)]
    }

    static func recordResidentBaseline() -> UInt64 {
        ProcessRSS.currentBytes()
    }

    static func residentGrowthBytes(baseline: UInt64, peak: UInt64) -> Int64 {
        Int64(peak) - Int64(baseline)
    }

}
