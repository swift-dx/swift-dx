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

@testable import DXRedis
import Foundation
import NIOCore
import Testing

// Pure-decode micro-benchmark, gated on REDIS_DECODE_BENCH so it never runs in
// the normal suite. It measures parseFrames throughput on a prebuilt array
// reply with no network involved, isolating the client-side decode cost.
// Run with: REDIS_DECODE_BENCH=1 swift test -c release --filter decodeArrayThroughput
@Suite("RESP decode micro-bench", .enabled(if: ProcessInfo.processInfo.environment["REDIS_DECODE_BENCH"] != nil))
struct RESPDecodeBenchTests {

    private func buildArrayReplies(arrays: Int, items: Int) -> [UInt8] {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(arrays * items * 12)
        for _ in 0..<arrays {
            buffer.append(contentsOf: Array("*\(items)\r\n".utf8))
            for index in 0..<items {
                let value = "item\(index)"
                buffer.append(contentsOf: Array("$\(value.utf8.count)\r\n".utf8))
                buffer.append(contentsOf: Array(value.utf8))
                buffer.append(contentsOf: Array("\r\n".utf8))
            }
        }
        return buffer
    }

    @Test("decodeArrayThroughput")
    func decodeArrayThroughput() throws {
        let arrays = 1000
        let items = 100
        let iterations = 300
        let bytes = buildArrayReplies(arrays: arrays, items: items)
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        var observed = 0
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            let parsed = try RedisInboundHandler.parseFrames(in: buffer, depthLimit: 64, maxBulkBytes: 1 << 20)
            observed &+= parsed.values.count
        }
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let totalItems = iterations * arrays * items
        let rate = seconds > 0 ? Int(Double(totalItems) / seconds) : 0
        print("[DECODE] arrays=\(observed) items=\(totalItems) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate)/s")
        #expect(observed == arrays * iterations)
    }
}
