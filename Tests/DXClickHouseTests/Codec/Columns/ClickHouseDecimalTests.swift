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

@Suite("ClickHouse Decimal types")
struct ClickHouseDecimalTests {

    @Test("Decimal32 typeName carries the scale")
    func decimal32TypeName() {
        #expect(ClickHouseColumnSpec.decimal32(scale: 2).typeName == "Decimal32(2)")
    }

    @Test("Decimal64 and Decimal128 typeNames carry the scale")
    func decimal64And128TypeNames() {
        #expect(ClickHouseColumnSpec.decimal64(scale: 8).typeName == "Decimal64(8)")
        #expect(ClickHouseColumnSpec.decimal128(scale: 18).typeName == "Decimal128(18)")
    }

    @Test("Decimal32 typeName + parser round-trip preserves scale")
    func decimal32RoundTrip() throws {
        let original: ClickHouseColumnSpec = .decimal32(scale: 4)
        let parsed = try ClickHouseTypeNameParser.parse(original.typeName)
        #expect(parsed == original)
    }

    @Test("Decimal(P, S) alias picks the right underlying width based on precision")
    func decimalAliasPicksWidthByPrecision() throws {
        let cases: [(input: String, expected: ClickHouseColumnSpec)] = [
            ("Decimal(5, 2)", .decimal32(scale: 2)),
            ("Decimal(9, 0)", .decimal32(scale: 0)),
            ("Decimal(10, 4)", .decimal64(scale: 4)),
            ("Decimal(18, 8)", .decimal64(scale: 8)),
            ("Decimal(20, 6)", .decimal128(scale: 6)),
            ("Decimal(38, 10)", .decimal128(scale: 10)),
        ]
        for (input, expected) in cases {
            let parsed = try ClickHouseTypeNameParser.parse(input)
            #expect(parsed == expected, "input \(input) parsed to \(parsed), expected \(expected)")
        }
    }

    @Test("Decimal(P, S) with precision > 38 maps to Decimal256 (76-digit max) — Decimal precision above 76 throws")
    func decimalPrecisionMapsToDecimal256OrThrows() throws {
        // Now supported: Decimal(50, 8) → Decimal256(8)
        #expect(try ClickHouseTypeNameParser.parse("Decimal(50, 8)") == .decimal256(scale: 8))
        // Above 76 digits: still throws
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("Decimal(100, 8)")
        }
    }

    @Test("Decimal32 wire format is identical to Int32 — registry decodes through Int32 column")
    func decimal32WireMatchesInt32() throws {
        let spec: ClickHouseColumnSpec = .decimal32(scale: 2)
        var buffer = ByteBuffer()
        // Decimal32(2) representing values 1.50, 23.00, -7.25
        buffer.writeClickHouseFixedWidthIntegers([Int32(150), Int32(2300), Int32(-725)])

        let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: 3, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [150, 2300, -725])
        #expect(typed.spec == spec)
    }

    @Test("Decimal128 wire format is identical to Int128 — registry decodes through Int128 column")
    func decimal128WireMatchesInt128() throws {
        let spec: ClickHouseColumnSpec = .decimal128(scale: 18)
        let original: [Int128] = [Int128.min, -1, 0, 1, Int128.max]
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers(original)

        let column = try ClickHouseColumnRegistry.decode(spec: spec, rows: original.count, from: &buffer)
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int128>)
        #expect(typed.values == original)
    }

    @Test("public typed-INSERT API converts .decimal32 to a Decimal32-spec'd Int32 column")
    func publicAPIConvertsDecimal32() throws {
        let column = try ClickHouseClient.toInternalColumn(.decimal32([100, 200, -50], scale: 2))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [100, 200, -50])
        #expect(typed.spec == .decimal32(scale: 2))
    }

    @Test("public typed-INSERT API converts .decimal128 with arbitrary scale")
    func publicAPIConvertsDecimal128() throws {
        let scaled: [Int128] = [1_000_000_000_000_000_000, -1_000_000_000_000_000_000, 0]
        let column = try ClickHouseClient.toInternalColumn(.decimal128(scaled, scale: 18))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int128>)
        #expect(typed.values == scaled)
        #expect(typed.spec == .decimal128(scale: 18))
    }

}
