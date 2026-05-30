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

@Suite("ClickHouse enum types")
struct ClickHouseEnumTests {

    @Test("Enum8 typeName escapes apostrophes in value names as doubled-quotes")
    func enum8TypeNameEscapesApostrophes() {
        let spec: ClickHouseColumnSpec = .enum8([
            .init(name: "alpha", value: 0),
            .init(name: "It's busy", value: 1),
        ])
        #expect(spec.typeName == "Enum8('alpha' = 0, 'It''s busy' = 1)")
    }

    @Test("Enum16 typeName preserves negative values")
    func enum16TypeNamePreservesNegativeValues() {
        let spec: ClickHouseColumnSpec = .enum16([
            .init(name: "low", value: -1000),
            .init(name: "high", value: 30_000),
        ])
        #expect(spec.typeName == "Enum16('low' = -1000, 'high' = 30000)")
    }

    @Test("Enum8 parses through the type-name parser preserving names and values")
    func enum8ParsesAndRoundTrips() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Enum8('IDLE' = 0, 'BUSY' = 1, 'ERROR' = 2)")
        #expect(parsed == .enum8([
            .init(name: "IDLE", value: 0),
            .init(name: "BUSY", value: 1),
            .init(name: "ERROR", value: 2),
        ]))
    }

    @Test("Enum16 parses with non-contiguous integer values")
    func enum16ParsesNonContiguousValues() throws {
        let parsed = try ClickHouseTypeNameParser.parse("Enum16('a' = -100, 'b' = 0, 'c' = 30000)")
        #expect(parsed == .enum16([
            .init(name: "a", value: -100),
            .init(name: "b", value: 0),
            .init(name: "c", value: 30_000),
        ]))
    }

    @Test("Enum8 wire format is identical to Int8 — registry decodes to a FixedWidthInteger column")
    func enum8WireFormatMatchesInt8() throws {
        let spec: ClickHouseColumnSpec = .enum8([
            .init(name: "OK", value: 0),
            .init(name: "FAIL", value: 1),
        ])
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([Int8(0), 1, 0, 1, 0])

        let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: 5, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int8>)
        #expect(typed.values == [0, 1, 0, 1, 0])
        #expect(typed.spec == spec)
    }

    @Test("Enum16 wire format is identical to Int16 — registry decodes to a FixedWidthInteger column")
    func enum16WireFormatMatchesInt16() throws {
        let spec: ClickHouseColumnSpec = .enum16([
            .init(name: "low", value: -1),
            .init(name: "high", value: 1000),
        ])
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([Int16(-1), 1000, -1])

        let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: 3, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int16>)
        #expect(typed.values == [-1, 1000, -1])
    }

    @Test("Enum8 with a value that overflows Int8 surfaces a malformed type name error")
    func enum8WithOverflowingValueRejected() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("Enum8('overflow' = 200)")
        }
    }

    @Test("Enum8 typeName + parser round-trip preserves apostrophes via doubled-quote escape")
    func enum8RoundTripWithApostrophes() throws {
        let original: ClickHouseColumnSpec = .enum8([
            .init(name: "user's", value: 0),
            .init(name: "admin's", value: 1),
        ])
        let parsed = try ClickHouseTypeNameParser.parse(original.typeName)
        #expect(parsed == original)
    }

}
