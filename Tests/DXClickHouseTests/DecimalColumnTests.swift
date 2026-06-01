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

@Suite("DXClickHouse Decimal columns")
struct ClickHouseDecimalColumnTests {

    struct D64Row: Codable, Sendable, Equatable { let v: ClickHouseDecimal }
    struct D128Row: Codable, Sendable, Equatable { let v: ClickHouseDecimal }

    @Test("Decimal(18, 4) reports the aliased type name and writes 8 little-endian bytes")
    func decimal64WireBytes() throws {
        let value = ClickHouseDecimal(unscaled: 1_234_567, precision: 18, scale: 4)
        let columns = try ClickHouseRowEncoder().encode([D64Row(v: value)])
        #expect(columns[0].column.typeName == "Decimal(18, 4)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        var expected: [UInt8] = []
        withUnsafeBytes(of: UInt64(1_234_567).littleEndian) { expected.append(contentsOf: $0) }
        #expect(Array(packet.suffix(8)) == expected)
    }

    @Test("Decimal(18, 4) decodes back through a hand-built column")
    func decimal64DecodeRoundTrip() throws {
        let value = ClickHouseDecimal(unscaled: 1_234_567, precision: 18, scale: 4)
        let decoded: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "v", column: .decimal([value], precision: 18, scale: 4))
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: D64Row.self, columns: decoded, rowCount: 1)
        #expect(rows == [D64Row(v: value)])
    }

    @Test("Negative Decimal64 sign-extends into 8 little-endian bytes")
    func decimal64NegativeWire() throws {
        let value = ClickHouseDecimal(unscaled: -1, precision: 18, scale: 2)
        let columns = try ClickHouseRowEncoder().encode([D64Row(v: value)])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(8)) == [UInt8](repeating: 0xFF, count: 8))
    }

    @Test("Decimal(38, 10) writes 16 little-endian bytes")
    func decimal128WireBytes() throws {
        let value = ClickHouseDecimal(limb0: 0x0102_0304_0506_0708, limb1: 0, limb2: 0, limb3: 0, precision: 38, scale: 10)
        let columns = try ClickHouseRowEncoder().encode([D128Row(v: value)])
        #expect(columns[0].column.typeName == "Decimal(38, 10)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(16)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("Decoder parses the aliased Decimal(P, S) type name from a block")
    func decimalAliasParse() throws {
        var body: [UInt8] = []
        withUnsafeBytes(of: UInt64(7_654_321).littleEndian) { body.append(contentsOf: $0) }
        let block = ClickHouseBlock(
            rowCount: 1,
            columnCount: 1,
            columnNames: ["v"],
            columnTypes: ["Decimal(18, 4)"],
            bodyStart: 0,
            bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        guard case .decimal(let values, let precision, let scale) = columns[0].column else {
            Issue.record("expected a decimal column, got \(columns[0].column.typeName)")
            return
        }
        #expect(precision == 18)
        #expect(scale == 4)
        #expect(values == [ClickHouseDecimal(unscaled: 7_654_321, precision: 18, scale: 4)])
    }

    @Test("Decoder parses the width-suffixed Decimal64(S) type name from a block")
    func decimalSuffixParse() throws {
        var body: [UInt8] = []
        withUnsafeBytes(of: UInt64(42).littleEndian) { body.append(contentsOf: $0) }
        let block = ClickHouseBlock(
            rowCount: 1,
            columnCount: 1,
            columnNames: ["v"],
            columnTypes: ["Decimal64(4)"],
            bodyStart: 0,
            bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        guard case .decimal(let values, let precision, let scale) = columns[0].column else {
            Issue.record("expected a decimal column, got \(columns[0].column.typeName)")
            return
        }
        #expect(precision == 18)
        #expect(scale == 4)
        #expect(values == [ClickHouseDecimal(unscaled: 42, precision: 18, scale: 4)])
    }
}
