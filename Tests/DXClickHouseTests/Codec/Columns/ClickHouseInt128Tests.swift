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

@Suite("ClickHouse Int128 / UInt128")
struct ClickHouseInt128Tests {

    @Test("Int128 typeName + parser round-trip")
    func int128TypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.int128.typeName == "Int128")
        let parsed = try ClickHouseTypeNameParser.parse("Int128")
        #expect(parsed == .int128)
    }

    @Test("UInt128 typeName + parser round-trip")
    func uint128TypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.uint128.typeName == "UInt128")
        let parsed = try ClickHouseTypeNameParser.parse("UInt128")
        #expect(parsed == .uint128)
    }

    @Test("Int128 boundary values round-trip through the registry")
    func int128BoundaryRoundTrip() throws {
        let original: [Int128] = [Int128.min, -1, 0, 1, Int128.max]
        let column = ClickHouseFixedWidthIntegerColumn<Int128>(spec: .int128, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 16)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .int128, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFixedWidthIntegerColumn<Int128>)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("UInt128 boundary values round-trip through the registry")
    func uint128BoundaryRoundTrip() throws {
        let original: [UInt128] = [0, 1, UInt128(UInt64.max), UInt128.max]
        let column = ClickHouseFixedWidthIntegerColumn<UInt128>(spec: .uint128, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 16)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .uint128, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFixedWidthIntegerColumn<UInt128>)
        #expect(typed.values == original)
    }

    @Test("Int128 wire encoding is 16 bytes little-endian")
    func int128WireBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(Int128(0x0102030405060708))
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        #expect(bytes == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    @Test("Int128 max produces all-ones except top bit")
    func int128MaxBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(Int128.max)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        // Int128.max = 0x7F_FF...FF, in LE = bytes[0..14] = 0xFF, bytes[15] = 0x7F
        #expect(bytes.dropLast() == ArraySlice(repeating: UInt8(0xFF), count: 15))
        #expect(bytes.last == 0x7F)
    }

    @Test("UInt128 max produces all-ones bytes")
    func uint128MaxBytes() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthInteger(UInt128.max)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16) ?? []
        #expect(bytes == Array(repeating: UInt8(0xFF), count: 16))
    }

    @Test("public typed-INSERT API converts .int128 to a FixedWidthInteger<Int128> column")
    func publicAPIConvertsInt128() throws {
        let column = try ClickHouseClient.toInternalColumn(.int128([Int128.min, 0, Int128.max]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int128>)
        #expect(typed.values == [Int128.min, 0, Int128.max])
        #expect(typed.spec == .int128)
    }

    @Test("public typed-INSERT API converts .uint128 to a FixedWidthInteger<UInt128> column")
    func publicAPIConvertsUInt128() throws {
        let column = try ClickHouseClient.toInternalColumn(.uint128([0, UInt128(UInt64.max), UInt128.max]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt128>)
        #expect(typed.values == [0, UInt128(UInt64.max), UInt128.max])
        #expect(typed.spec == .uint128)
    }

}
