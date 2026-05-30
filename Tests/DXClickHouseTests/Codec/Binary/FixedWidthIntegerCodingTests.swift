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

@Suite("ClickHouse fixed-width integer coding")
struct FixedWidthIntegerCodingTests {

    @Test("Int8 round-trips at edges")
    func int8RoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [Int8] = [Int8.min, -1, 0, 1, Int8.max]
        buffer.writeClickHouseFixedWidthIntegers(values)
        #expect(buffer.readableBytes == values.count)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(Int8.self, rows: values.count)
        #expect(decoded == values)
        #expect(buffer.readableBytes == 0)
    }

    @Test("UInt8 round-trips at edges")
    func uint8RoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [UInt8] = [0, 1, 127, 128, UInt8.max]
        buffer.writeClickHouseFixedWidthIntegers(values)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(UInt8.self, rows: values.count)
        #expect(decoded == values)
    }

    @Test("Int16 uses two bytes per value in little-endian")
    func int16ByteOrder() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(Int16(0x1234))
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 2) ?? []
        #expect(bytes == [0x34, 0x12])
    }

    @Test("Int32 uses four bytes per value in little-endian")
    func int32ByteOrder() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(Int32(0x12345678))
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 4) ?? []
        #expect(bytes == [0x78, 0x56, 0x34, 0x12])
    }

    @Test("Int64 uses eight bytes per value in little-endian")
    func int64ByteOrder() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(Int64(0x0102030405060708))
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 8) ?? []
        #expect(bytes == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    @Test("Int32 round-trips at edges")
    func int32RoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [Int32] = [Int32.min, -1, 0, 1, Int32.max]
        buffer.writeClickHouseFixedWidthIntegers(values)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: values.count)
        #expect(decoded == values)
    }

    @Test("Int64 round-trips at edges")
    func int64RoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [Int64] = [Int64.min, -1, 0, 1, Int64.max]
        buffer.writeClickHouseFixedWidthIntegers(values)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(Int64.self, rows: values.count)
        #expect(decoded == values)
    }

    @Test("UInt64 round-trips at edges")
    func uint64RoundTrip() throws {
        var buffer = ByteBuffer()
        let values: [UInt64] = [0, 1, UInt64(Int64.max), UInt64.max]
        buffer.writeClickHouseFixedWidthIntegers(values)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(UInt64.self, rows: values.count)
        #expect(decoded == values)
    }

    @Test("zero-row read consumes zero bytes")
    func zeroRowsIsNoOp() throws {
        var buffer = ByteBuffer()
        let decoded = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: 0)
        #expect(decoded.isEmpty)
        #expect(buffer.readableBytes == 0)
    }

    @Test("read truncation surfaces a typed error before returning a partial array")
    func truncationSurfaces() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([Int32(1), Int32(2)])
        var truncated = ByteBuffer()
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 6) ?? []
        truncated.writeBytes(bytes)
        #expect(throws: ClickHouseError.self) {
            try truncated.readClickHouseFixedWidthIntegers(Int32.self, rows: 2)
        }
    }

    @Test("large row counts pre-allocate without reallocation surprises")
    func largeBatchRoundTrip() throws {
        var buffer = ByteBuffer()
        let values = (0..<10_000).map { Int32($0) }
        buffer.writeClickHouseFixedWidthIntegers(values)
        let decoded = try buffer.readClickHouseFixedWidthIntegers(Int32.self, rows: values.count)
        #expect(decoded == values)
        #expect(buffer.readableBytes == 0)
    }

    @Test("unsigned and signed produce identical bytes for non-negative values")
    func signedAndUnsignedAlign() {
        var bufferA = ByteBuffer()
        var bufferB = ByteBuffer()
        bufferA.writeClickHouseFixedWidthInteger(Int32(42))
        bufferB.writeClickHouseFixedWidthInteger(UInt32(42))
        let bytesA = bufferA.getBytes(at: bufferA.readerIndex, length: 4) ?? []
        let bytesB = bufferB.getBytes(at: bufferB.readerIndex, length: 4) ?? []
        #expect(bytesA == bytesB)
    }

}
