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
import NIOCore
import Testing

// Locks in the bulk-memcpy fast path's byte-level equivalence with
// the per-element reference path. If a future change accidentally
// produces a different wire layout for fixed-width integer columns,
// these tests fail loudly.
@Suite("ByteBuffer fixed-width integer bulk read/write — byte-level equivalence")
struct ByteBufferFixedWidthIntegerBulkPathTests {

    private static func referenceEncode<T: FixedWidthInteger>(_ values: [T]) -> ByteBuffer {
        var buffer = ByteBuffer()
        for value in values {
            buffer.writeInteger(value, endianness: .little)
        }
        return buffer
    }

    @Test("write of an empty array produces zero bytes (no length prefix)")
    func writeEmptyProducesNoBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([] as [Int32])
        #expect(buffer.readableBytes == 0)
    }

    @Test("write of [Int32] produces exactly 4 bytes per element")
    func writeInt32SizeMatchesElementSize() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([1, 2, 3, 4] as [Int32])
        #expect(buffer.readableBytes == 16, "4 elements × 4 bytes/Int32")
    }

    @Test("write of [Int64] produces exactly 8 bytes per element")
    func writeInt64SizeMatchesElementSize() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([Int64.min, 0, Int64.max])
        #expect(buffer.readableBytes == 24)
    }

    @Test("write of [Int32] produces the same bytes as the reference per-element path")
    func writeInt32MatchesReference() {
        let values: [Int32] = [Int32.min, -1, 0, 1, Int32.max, 0x12345678]
        var fast = ByteBuffer()
        fast.writeClickHouseFixedWidthIntegers(values)
        let reference = Self.referenceEncode(values)
        #expect(fast == reference)
    }

    @Test("write of [UInt64] across boundary values matches the reference path")
    func writeUInt64MatchesReference() {
        let values: [UInt64] = [0, 1, UInt64.max, 0xFEDCBA9876543210, 0x0102030405060708]
        var fast = ByteBuffer()
        fast.writeClickHouseFixedWidthIntegers(values)
        let reference = Self.referenceEncode(values)
        #expect(fast == reference)
    }

    @Test("write of a 1000-element [Int32] array matches the reference path")
    func writeLargeArrayMatchesReference() {
        let values: [Int32] = (0..<1000).map { Int32($0 * 7 - 500) }
        var fast = ByteBuffer()
        fast.writeClickHouseFixedWidthIntegers(values)
        let reference = Self.referenceEncode(values)
        #expect(fast == reference)
    }

    @Test("read recovers exactly what write produced for [Int32]")
    func writeReadRoundTripInt32() throws {
        let original: [Int32] = [Int32.min, -1, 0, 1, Int32.max]
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(original)
        let restored: [Int32] = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: original.count)
        #expect(restored == original)
        #expect(buffer.readableBytes == 0, "all bytes consumed")
    }

    @Test("read recovers exactly what write produced for [Int64] with boundary values")
    func writeReadRoundTripInt64() throws {
        let original: [Int64] = [Int64.min, -1, 0, 1, Int64.max, 0x7FFF_FFFF_FFFF_FFFF]
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(original)
        let restored = try buffer.readClickHouseFixedWidthIntegers(Int64.self, rows: original.count)
        #expect(restored == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("read recovers a large [UInt32] array exactly")
    func writeReadRoundTripUInt32Large() throws {
        let original: [UInt32] = (0..<10_000).map { UInt32($0) }
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(original)
        let restored = try buffer.readClickHouseFixedWidthIntegers(UInt32.self, rows: original.count)
        #expect(restored == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("read of zero rows returns empty array without consuming any bytes")
    func readZeroRowsConsumesNothing() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0xAA, 0xBB, 0xCC, 0xDD] as [UInt8])
        let initial = buffer.readableBytes
        let restored = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: 0)
        #expect(restored.isEmpty)
        #expect(buffer.readableBytes == initial, "no bytes consumed")
    }

    @Test("read throws truncatedBuffer when not enough bytes are available")
    func readThrowsOnTruncated() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x01, 0x02, 0x03] as [UInt8])  // 3 bytes, can't fit one Int32
        #expect(throws: ClickHouseError.self) {
            try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: 1)
        }
    }

    @Test("read advances the reader index by exactly rows × elementSize bytes")
    func readAdvancesReaderByExpectedBytes() throws {
        let values: [Int64] = [1, 2, 3, 4]
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(values)
        // Append a sentinel after the integers
        buffer.writeBytes([0xCA, 0xFE, 0xBA, 0xBE] as [UInt8])

        _ = try buffer.readClickHouseFixedWidthIntegers(Int64.self, rows: 4)
        #expect(buffer.readableBytes == 4, "reader advanced past the integers, sentinel still readable")
        let sentinel: [UInt8] = buffer.readBytes(length: 4) ?? []
        #expect(sentinel == [0xCA, 0xFE, 0xBA, 0xBE])
    }

    @Test("writing 1000 Int32s in one bulk call, then reading them back, preserves every element")
    func bulkWriteThenBulkReadLargePayload() throws {
        let original: [Int32] = (0..<1000).map { Int32($0 - 500) }
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(original)
        let restored = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: original.count)
        #expect(restored == original)
        #expect(buffer.readableBytes == 0)
    }

}
