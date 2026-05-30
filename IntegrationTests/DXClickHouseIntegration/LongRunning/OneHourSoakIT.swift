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
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// One-hour mixed-workload soak against a live broker. Gated by
// CH_LONG_RUNNING=1 so a normal test run skips it. Drives a rotating
// scalar/select/insert mix on a single shared client for the full
// duration, then asserts:
//
//   1. Final RSS sits within a generous absolute bound above the
//      post-warmup baseline (a real per-iteration leak compounds far
//      past this in an hour and trips the bound).
//   2. P99 latency in the last 10% of the run sits within 20% of P99
//      in the first 10% of the run (drift detector).
//   3. Zero recorded errors.
@Suite(
    "DXClickHouse LongRunning: 1-hour soak (CH_LONG_RUNNING=1)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil && ProcessInfo.processInfo.environment["CH_LONG_RUNNING"] == "1"),
    .serialized
)
struct OneHourSoakIT {

    private static let soakDurationSeconds: Int = 3_600
    private static let warmupRows = 20_000
    private static let insertBatchRows = 100
    private static let p99DriftCeilingFraction: Double = 0.20
    private static let residentGrowthCeilingBytes: Int64 = 500 * 1024 * 1024

    struct SoakRow: Codable, Sendable {
        let id: UInt64
        let bucket: String
        let value: Double
    }

    @Test("1-hour soak: mixed workload, RSS bounded, P99 drift inside 20%, zero errors")
    func oneHourSoak() async throws {
        let client = try await LongRunningSupport.makeClient()
        defer { Task { await client.close() } }
        let table = LongRunningSupport.uniqueTable(prefix: "soak1h")
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                bucket String,
                value Float64
            ) ENGINE = MergeTree ORDER BY id
            """)
        defer {
            Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") }
        }
        // Warmup so the RSS baseline reflects post-warmup steady state.
        let warmupRows: [SoakRow] = (0..<Self.warmupRows).map { index in
            SoakRow(id: UInt64(index), bucket: "warmup-\(index % 8)", value: Double(index) * 0.5)
        }
        _ = try await client.insert(into: table, rows: warmupRows)
        try await Task.sleep(for: .milliseconds(500))
        let baselineRSS = currentRSS()

        let firstWindow = OneHourSoakWindow()
        let lastWindow = OneHourSoakWindow()
        let firstWindowBoundary = Self.soakDurationSeconds / 10
        let lastWindowBoundary = Self.soakDurationSeconds - (Self.soakDurationSeconds / 10)
        let startInstant = ContinuousClock.now
        let endInstant = startInstant.advanced(by: .seconds(Self.soakDurationSeconds))
        var errors = 0
        var inserted: UInt64 = UInt64(Self.warmupRows)
        var iteration: UInt64 = 0
        while ContinuousClock.now < endInstant {
            iteration &+= 1
            let elapsedSecondsSoFar = Int((ContinuousClock.now - startInstant).components.seconds)
            let inFirstWindow = elapsedSecondsSoFar < firstWindowBoundary
            let inLastWindow = elapsedSecondsSoFar >= lastWindowBoundary
            let mode = iteration % 3
            let opStart = ContinuousClock.now
            do {
                switch mode {
                case 0:
                    let count = try await client.scalar(
                        "SELECT toUInt64(count()) FROM \(table)",
                        as: UInt64.self,
                        timeout: .seconds(15)
                    )
                    if count == 0 { errors += 1 }
                case 1:
                    let rowsToInsert: [SoakRow] = (0..<Self.insertBatchRows).map { localIndex in
                        SoakRow(
                            id: inserted + UInt64(localIndex),
                            bucket: "bucket-\(localIndex % 4)",
                            value: Double(localIndex) * 1.5
                        )
                    }
                    let summary = try await client.insert(
                        into: table,
                        rows: rowsToInsert,
                        timeout: .seconds(15)
                    )
                    inserted += UInt64(summary.rowsSent)
                default:
                    struct LimitedRow: Decodable, Sendable { let id: UInt64; let value: Double }
                    let rows = try await client.selectAll(
                        "SELECT id, value FROM \(table) ORDER BY id DESC LIMIT 200",
                        as: LimitedRow.self,
                        timeout: .seconds(15)
                    )
                    if rows.isEmpty { errors += 1 }
                }
            } catch {
                errors += 1
            }
            let elapsedMicroseconds = LongRunningSupport.microsecondsSince(opStart)
            if inFirstWindow { firstWindow.record(microseconds: elapsedMicroseconds) }
            if inLastWindow { lastWindow.record(microseconds: elapsedMicroseconds) }
        }

        let finalRSS = currentRSS()
        let firstP99 = firstWindow.p99Microseconds()
        let lastP99 = lastWindow.p99Microseconds()

        #expect(errors == 0, "soak recorded \(errors) errors across the run")
        if baselineRSS > 0 && finalRSS > 0 {
            let growth = finalRSS - baselineRSS
            #expect(
                growth <= Self.residentGrowthCeilingBytes,
                "RSS grew by \(growth) bytes from baseline \(baselineRSS) (ceiling \(Self.residentGrowthCeilingBytes))"
            )
        }
        if firstP99 > 0 && lastP99 > 0 {
            let ceiling = Int64(Double(firstP99) * (1.0 + Self.p99DriftCeilingFraction))
            #expect(
                lastP99 <= ceiling,
                "P99 drift: first=\(firstP99)us last=\(lastP99)us ceiling=\(ceiling)us"
            )
        }
    }

    private static func currentRSS() -> Int64 {
        currentResidentBytes()
    }

    @inline(__always)
    private static func currentResidentBytes() -> Int64 {
        #if canImport(Glibc)
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
        #elseif canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
        #else
        return 0
        #endif
    }

    private func currentRSS() -> Int64 { Self.currentResidentBytes() }
}

// Per-window accumulator. Mirrored on the soak suites' shape so the
// percentile computation matches what the existing soak reporters use.
final class OneHourSoakWindow: @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Int64] = []

    func record(microseconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        samples.append(microseconds)
    }

    func p99Microseconds() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var sorted = samples
        sorted.sort()
        return LongRunningSupport.percentileMicroseconds(sorted, 0.99)
    }
}
