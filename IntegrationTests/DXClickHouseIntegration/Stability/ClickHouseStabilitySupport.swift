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
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Namespace that holds the three stability test suites for
// DXClickHouse. Nesting the suites inside `Stability` lets a single
// `--filter DXClickHouseIntegration.Stability` regex select all
// three from `swift test`; each suite's display name and the test
// method names stay unambiguous in the run report.
enum Stability {}

// Shared scaffolding for the stability suites under
// IntegrationTests/DXClickHouseIntegration/Stability/. Mirrors the
// DXClickHouse soak helpers but targets DXClickHouse and reads its
// own env vars so the two stability suites can be run side by side
// without colliding on duration knobs.
//
// Env vars consumed by the raw stability suite:
//
//   CH_INTEGRATION_HOST / PORT / USER / PASSWORD / DATABASE
//                                  ClickHouse endpoint, shared with
//                                  the other raw integration suites.
//   CH_STABILITY_FULL=1            Extends the soak from 5 min to
//                                  30 min and the concurrency stress
//                                  from 5 min to 15 min. Off by
//                                  default to keep CI under 6 min.
//   CH_RAW_STABILITY_SOAK_SECONDS  Override soak duration in seconds.
//   CH_RAW_STABILITY_CONCURRENCY_SECONDS
//                                  Override concurrency stress
//                                  duration in seconds.
enum ClickHouseStabilitySupport {

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

    static var isFullRun: Bool {
        ProcessInfo.processInfo.environment["CH_STABILITY_FULL"] == "1"
    }

    static var soakDurationSeconds: Int {
        if let override = ProcessInfo.processInfo.environment["CH_RAW_STABILITY_SOAK_SECONDS"], let value = Int(override) {
            return value
        }
        return isFullRun ? 1_800 : 300
    }

    static var concurrencyStressDurationSeconds: Int {
        if let override = ProcessInfo.processInfo.environment["CH_RAW_STABILITY_CONCURRENCY_SECONDS"], let value = Int(override) {
            return value
        }
        return isFullRun ? 900 : 300
    }

    // The shared concurrency-stress pool size. 16 connections is the
    // canonical "production" sizing the raw pool benchmarks use; 100
    // concurrent Tasks contend behind that fan-in so the test exercises
    // both fast-path acquire and waiter suspension.
    static var concurrencyPoolMaxConnections: Int { 16 }

    static var concurrencyStressTaskCount: Int { 100 }

    static func makeAsyncConnection() async throws -> AsyncClickHouseConnection {
        try await AsyncClickHouseConnection(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    static func makePool(
        maxConnections: Int,
        minConnections: Int = 1,
        acquireTimeout: Duration = .seconds(30)
    ) async throws -> ClickHouseConnectionPool {
        try await ClickHouseConnectionPool(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            minConnections: minConnections,
            maxConnections: maxConnections,
            acquireTimeout: acquireTimeout
        )
    }

    static func uniqueTable(prefix: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "\(database).raw_stab_\(prefix)_\(suffix)"
    }

    static func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
        let duration = ContinuousClock.now - start
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }

    static func percentileMicroseconds(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
        if sortedSamples.isEmpty { return 0 }
        let lastIndex = sortedSamples.count - 1
        let position = Int((Double(lastIndex) * fraction).rounded())
        return sortedSamples[min(max(position, 0), lastIndex)]
    }
}

// Splitmix64-style deterministic RNG. Matches the shape used by the
// DXClickHouse soak suite so a single bug class (off-by-one in the
// mode-cursor RNG, e.g.) surfaces consistently across both stability
// surfaces.
struct ClickHouseStabilityRandom: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        var s = seed &+ 0x9E37_79B9_7F4A_7C15
        s = (s ^ (s >> 30)) &* 0xBF58_476D_1CE4_E5B9
        s = (s ^ (s >> 27)) &* 0x94D0_49BB_1331_11EB
        s = s ^ (s >> 31)
        self.state = s
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var result = state
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}

// Minute-window latency accumulator. Stores per-operation microseconds
// + error count; computes P50 / P95 / P99 on demand so the soak
// reporter doesn't recompute on the hot path.
struct ClickHouseStabilityWindow: Sendable {

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
        return ClickHouseStabilitySupport.percentileMicroseconds(sorted, 0.99)
    }

    func p95Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return ClickHouseStabilitySupport.percentileMicroseconds(sorted, 0.95)
    }

    func p50Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return ClickHouseStabilitySupport.percentileMicroseconds(sorted, 0.50)
    }
}

// Reads VmRSS from /proc/self/status on Linux and falls back to
// mach_task_basic_info on macOS. Returns 0 on platforms without a
// supported path. The soak reporter compares post-warmup baseline
// against the run's peak to surface leaks.
enum ClickHouseStabilityProcessRSS {

    static func currentBytes() -> Int64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
        #elseif canImport(Glibc)
        guard let raw = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return 0
        }
        for line in raw.split(separator: "\n") {
            if line.hasPrefix("VmRSS:") {
                let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if columns.count >= 2, let kilobytes = Int64(columns[1]) {
                    return kilobytes * 1024
                }
            }
        }
        return 0
        #else
        return 0
        #endif
    }
}

// Counts open file descriptors by enumerating /proc/self/fd on Linux.
// macOS falls back to proc_pidinfo, which requires linking a separate
// framework — the fd-leak invariant is most meaningful on Linux (the
// production target) so the macOS path returns 0 and the assertion
// short-circuits.
enum ClickHouseStabilityFileDescriptorCount {

    static func currentCount() -> Int {
        #if canImport(Glibc)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
            return 0
        }
        return entries.count
        #else
        return 0
        #endif
    }
}
