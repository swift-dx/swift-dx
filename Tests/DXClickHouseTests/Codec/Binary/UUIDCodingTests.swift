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
import Testing

@Suite("ClickHouse UUID coding")
struct UUIDCodingTests {

    @Test("each 8-byte half is reversed on the wire relative to the RFC 4122 layout")
    func wireFormatReversesEachHalf() throws {
        let uuid = try #require(UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F"))
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUID(uuid)
        #expect(buffer.readableBytes == 16)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        #expect(bytes == [
            0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00,
            0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09, 0x08,
        ])
    }

    @Test("round-trips a representative UUID")
    func roundTripRepresentativeUUID() throws {
        let uuid = try #require(UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0"))
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUID(uuid)
        let decoded = try buffer.readClickHouseUUID()
        #expect(decoded == uuid)
        #expect(buffer.readableBytes == 0)
    }

    @Test("round-trips the all-zero UUID")
    func roundTripZeroUUID() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUID(uuid)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        #expect(bytes == Array(repeating: UInt8(0), count: 16))
        let decoded = try buffer.readClickHouseUUID()
        #expect(decoded == uuid)
    }

    @Test("round-trips the all-ones UUID")
    func roundTripAllOnesUUID() throws {
        let uuid = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUID(uuid)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        #expect(bytes == Array(repeating: UInt8(0xFF), count: 16))
        let decoded = try buffer.readClickHouseUUID()
        #expect(decoded == uuid)
    }

    @Test("round-trips a randomly generated UUID")
    func roundTripRandomUUID() throws {
        let uuid = UUID()
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUID(uuid)
        let decoded = try buffer.readClickHouseUUID()
        #expect(decoded == uuid)
    }

    @Test("batch encode and decode preserves order")
    func batchPreservesOrder() throws {
        let uuids = (0..<32).map { _ in UUID() }
        var buffer = ByteBuffer()
        buffer.writeClickHouseUUIDs(uuids)
        #expect(buffer.readableBytes == 16 * uuids.count)
        let decoded = try buffer.readClickHouseUUIDs(rows: uuids.count)
        #expect(decoded == uuids)
    }

    @Test("zero-row batch read is a no-op")
    func zeroRowBatchIsNoOp() throws {
        var buffer = ByteBuffer()
        let decoded = try buffer.readClickHouseUUIDs(rows: 0)
        #expect(decoded.isEmpty)
        #expect(buffer.readableBytes == 0)
    }

    @Test("truncated UUID read surfaces a typed error")
    func truncatedReadThrows() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0), count: 8))
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseUUID()
        }
    }

    @Test("bulk UUID encode + decode for 1M values stays under the fast-path budget — proves the bulk-memcpy + byte-swap path is engaged")
    func bulkUUIDFastPathStaysUnderBudget() throws {
        let count = 1_000_000
        var values: [UUID] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(UUID())
        }
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count * 16)

        let encodeStart = Date()
        buffer.writeClickHouseUUIDs(values)
        let encodeElapsed = Date().timeIntervalSince(encodeStart)
        #expect(buffer.readableBytes == count * 16)

        let decodeStart = Date()
        let decoded = try buffer.readClickHouseUUIDs(rows: count)
        let decodeElapsed = Date().timeIntervalSince(decodeStart)

        #expect(decoded.count == count)
        // Spot-check: round-trip preserves the UUIDs. Iterating all
        // 1M would dominate the test time; sampling 16 indices is
        // enough to catch a wholesale corruption regression.
        #expect(decoded[0] == values[0])
        #expect(decoded[count - 1] == values[count - 1])
        for sampleIndex in stride(from: 0, to: count, by: count / 16) {
            #expect(decoded[sampleIndex] == values[sampleIndex])
        }

        print("[UUID FAST-PATH] encode 1M UUIDs: \(String(format: "%.1f ms", encodeElapsed * 1000)), decode: \(String(format: "%.1f ms", decodeElapsed * 1000))")
        // A regression to the per-row writeInteger×2 / readInteger×2
        // loop on 1M UUIDs runs into the seconds; the bulk-memcpy +
        // byte-swap fast path completes well inside this budget even
        // on a loaded developer machine.
        #expect(encodeElapsed < 0.75,
                "UUID bulk encode regressed: \(String(format: "%.1fms", encodeElapsed * 1000)) — expected sub-750ms via the bulk-memcpy + byte-swap path")
        #expect(decodeElapsed < 0.75,
                "UUID bulk decode regressed: \(String(format: "%.1fms", decodeElapsed * 1000)) — expected sub-750ms via the bulk-memcpy + byte-swap path")
    }

    @Test("batch read declares the total byte deficit, not per-row")
    func batchTruncationCountsTotalBytes() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0), count: 31))
        do {
            _ = try buffer.readClickHouseUUIDs(rows: 2)
            Issue.record("expected truncation error")
        } catch let error as ClickHouseError {
            switch error {
            case .truncatedBuffer(let needed, let available):
                #expect(needed == 32)
                #expect(available == 31)
            default:
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

}
