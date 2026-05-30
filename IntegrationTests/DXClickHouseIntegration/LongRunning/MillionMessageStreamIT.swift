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

// One-million-row streaming consume against the server-side `numbers()`
// table function. Gated by CH_LONG_RUNNING=1. The point of the test is
// not throughput — it's leak detection on the streaming path. A typed
// AsyncThrowingStream iterated to completion against a 1M-row source
// must not accumulate per-row references, must drain the underlying
// transport buffers, and must close the connection cleanly at the end.
@Suite(
    "DXClickHouse LongRunning: 1M-row streaming consume (CH_LONG_RUNNING=1)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil && ProcessInfo.processInfo.environment["CH_LONG_RUNNING"] == "1"),
    .serialized
)
struct MillionMessageStreamIT {

    private static let rowCount: UInt64 = 1_000_000
    private static let rssGrowthCeilingBytes: Int64 = 200 * 1024 * 1024

    struct StreamedRow: Decodable, Sendable {
        let n: UInt64
        let payload: String
    }

    @Test("1M-row stream consume completes, observes every row, no RSS leak")
    func millionRowStreamConsume() async throws {
        let client = try await LongRunningSupport.makeClient()
        defer { Task { await client.close() } }
        // Warmup with a small scan so the post-warmup RSS reflects a
        // primed allocator rather than initial libc / Foundation arenas.
        struct WarmupRow: Decodable, Sendable { let n: UInt64 }
        var warmupSum: UInt64 = 0
        for try await row in client.select("SELECT toUInt64(number) AS n FROM numbers(10000)", as: WarmupRow.self) {
            warmupSum &+= row.n
        }
        #expect(warmupSum == 49_995_000)
        try await Task.sleep(for: .milliseconds(500))
        let baselineRSS = currentResidentBytes()

        var observed: UInt64 = 0
        var sumChecksum: UInt64 = 0
        let stream = client.select(
            "SELECT toUInt64(number) AS n, toString(number) AS payload FROM numbers(\(Self.rowCount))",
            as: StreamedRow.self
        )
        for try await row in stream {
            observed &+= 1
            sumChecksum &+= row.n
        }
        let finalRSS = currentResidentBytes()
        #expect(observed == Self.rowCount, "stream observed \(observed) rows; expected \(Self.rowCount)")
        // Sum of 0..(N-1) = N*(N-1)/2; for N=1_000_000 the checksum is 499_999_500_000.
        #expect(sumChecksum == 499_999_500_000)
        if baselineRSS > 0 && finalRSS > 0 {
            let growth = finalRSS - baselineRSS
            #expect(
                growth <= Self.rssGrowthCeilingBytes,
                "RSS grew by \(growth) bytes from baseline \(baselineRSS) (ceiling \(Self.rssGrowthCeilingBytes))"
            )
        }
    }

    private func currentResidentBytes() -> Int64 {
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
}
