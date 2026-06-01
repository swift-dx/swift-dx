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

@Suite("DXClickHouse Tuple column")
struct ClickHouseTupleColumnTests {

    struct PairRow: Codable, Sendable, Equatable {
        let pair: ClickHouseTuple
    }

    @Test("Tuple(UInt64, String) writes each element column sequentially with no delimiters")
    func encodeTupleBytes() throws {
        let columns = try ClickHouseRowEncoder().encode([
            PairRow(pair: ClickHouseTuple.uint64String(7, "ab")),
            PairRow(pair: ClickHouseTuple.uint64String(9, "c")),
        ])
        #expect(columns[0].column.typeName == "Tuple(UInt64, String)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        // UInt64 column [7, 9] LE, then String column "ab","c" length-prefixed.
        let expected = Self.uint64LE(7) + Self.uint64LE(9) + [2, 97, 98] + [1, 99]
        #expect(Array(packet.suffix(expected.count)) == expected)
    }

    @Test("Tuple(UInt64, String) round-trips through the typed decoder")
    func roundTripTupleUInt64String() throws {
        let rows = [
            PairRow(pair: ClickHouseTuple.uint64String(7, "ab")),
            PairRow(pair: ClickHouseTuple.uint64String(9, "c")),
        ]
        // UInt64 column 16 bytes, then String column 3 + 2 bytes.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 16 + 3 + 2)
        #expect(decoded.count == rows.count)
        #expect(decoded[0].pair.uint64FirstElement == 7)
        #expect(decoded[0].pair.stringSecondElement == "ab")
        #expect(decoded[1].pair.uint64FirstElement == 9)
        #expect(decoded[1].pair.stringSecondElement == "c")
    }

    @Test("Tuple(Float64, Float64) round-trips both little-endian elements")
    func roundTripTupleFloat64Pair() throws {
        let rows = [
            PairRow(pair: ClickHouseTuple.float64Pair(1.5, 2.5)),
            PairRow(pair: ClickHouseTuple.float64Pair(-3.25, 0.0)),
        ]
        #expect(rows[0].pair.elements == [.float64, .float64])
        // Two Float64 columns, each 2 rows * 8 bytes = 32 bytes total.
        let decoded = try Self.roundTrip(rows: rows, bodyLength: 32)
        #expect(decoded[0].pair.float64Element(at: 0) == 1.5)
        #expect(decoded[0].pair.float64Element(at: 1) == 2.5)
        #expect(decoded[1].pair.float64Element(at: 0) == -3.25)
        #expect(decoded[1].pair.float64Element(at: 1) == 0.0)
    }

    @Test("Named Tuple type name round-trips through parseTypedColumns")
    func namedTupleTypeNameRoundTrips() throws {
        // UInt64 column [42] LE, then String column "hi" length-prefixed.
        let body: [UInt8] = Self.uint64LE(42) + [2, 104, 105]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["pair"],
            columnTypes: ["Tuple(amount UInt64, label String)"],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        #expect(decoded[0].column.typeName == "Tuple(amount UInt64, label String)")
        let rows = try ClickHouseCodableDecoder.decodeRows(type: PairRow.self, columns: decoded, rowCount: 1)
        #expect(rows[0].pair.uint64FirstElement == 42)
        #expect(rows[0].pair.stringSecondElement == "hi")
    }

    private static func roundTrip(rows: [PairRow], bodyLength: Int) throws -> [PairRow] {
        let columns = try ClickHouseRowEncoder().encode(rows)
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let body = Array(packet.suffix(bodyLength))
        let block = ClickHouseBlock(
            rowCount: rows.count, columnCount: 1,
            columnNames: [columns[0].name],
            columnTypes: [columns[0].column.typeName],
            bodyStart: 0, bodyLength: body.count
        )
        let decoded = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        return try ClickHouseCodableDecoder.decodeRows(type: PairRow.self, columns: decoded, rowCount: rows.count)
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }
}
