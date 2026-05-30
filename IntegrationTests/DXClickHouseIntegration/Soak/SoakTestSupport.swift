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

// Shared scaffolding for the stability-validation suites in this
// directory. The soak / fault-injection / concurrency-stress suites
// share the env-var-gated configuration, the latency-bucket
// accumulator, and the connection-pool baseline configuration.
//
// The wall-clock duration is configurable via env vars so the CI
// runner can dial it in:
//
//   CH_SOAK_DURATION_SECONDS         (default 60, full-run target 600)
//   CH_CONCURRENCY_STRESS_SECONDS    (default 30, full-run target 300)
//   CH_FAULT_INJECTION_ITERATIONS    (default 3)
//
// Defaults match the CI envelope so the suite is always run end-to-
// end. The full-run targets match the spec (10-minute soak, 5-minute
// concurrency stress) and are opted into by setting the env vars
// before invoking `swift test`.
enum SoakTestSupport {

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

    static var soakDurationSeconds: Int {
        Int(ProcessInfo.processInfo.environment["CH_SOAK_DURATION_SECONDS"] ?? "60") ?? 60
    }

    static var concurrencyStressDurationSeconds: Int {
        Int(ProcessInfo.processInfo.environment["CH_CONCURRENCY_STRESS_SECONDS"] ?? "30") ?? 30
    }

    static var faultInjectionIterations: Int {
        Int(ProcessInfo.processInfo.environment["CH_FAULT_INJECTION_ITERATIONS"] ?? "3") ?? 3
    }

    static func uniqueTable(_ kind: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "\(database).soak_\(kind)_\(suffix)"
    }

    static func makeConfiguration(
        eventLoopGroup: EventLoopGroup,
        maxConnections: Int,
        endpoints: [ClickHouseEndpoint],
        acquireTimeout: ClickHouseClient.PoolAcquireTimeout = .waitUpTo(.seconds(30))
    ) -> ClickHouseClient.Configuration {
        .init(
            endpoints: endpoints,
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections,
            maxIdleConnections: maxConnections,
            acquireTimeout: acquireTimeout,
            eventLoopGroup: eventLoopGroup
        )
    }

    static func defaultEndpoints() -> [ClickHouseEndpoint] {
        [.init(host: host, port: port)]
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

}

// Soak-only latency bucket. Records per-minute P99 + error counts so
// the post-run assertion can compare minute 10 against minute 1 for
// drift, without retaining every sample in memory.
struct SoakWindow: Sendable {

    var samples: [Int64] = []
    var errors: Int = 0

    mutating func record(microseconds: Int64) {
        samples.append(microseconds)
    }

    mutating func recordError() {
        errors += 1
    }

    func p99Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return SoakTestSupport.percentile(sorted, 0.99)
    }

    func medianMicroseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return SoakTestSupport.percentile(sorted, 0.5)
    }

}
