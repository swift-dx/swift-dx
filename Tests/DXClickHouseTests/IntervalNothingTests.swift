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
import Testing

@Suite("DXClickHouse Interval / Nothing / SimpleAggregateFunction")
struct ClickHouseIntervalNothingTests {

    struct Ival: Codable, Sendable, Equatable { let span: ClickHouseInterval }

    @Test("Interval writes a little-endian Int64 and reproduces its kind in the type name")
    func intervalWire() throws {
        let columns = try ClickHouseRowEncoder().encode([Ival(span: ClickHouseInterval(value: 5, kind: .day))])
        #expect(columns[0].column.typeName == "IntervalDay")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        var expected: [UInt8] = []
        withUnsafeBytes(of: Int64(5).littleEndian) { expected.append(contentsOf: $0) }
        #expect(Array(packet.suffix(8)) == expected)
    }

    @Test("Interval decodes back with the correct kind and value")
    func intervalDecode() throws {
        let decoded: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "span", column: .interval([5, -3], kind: .second))
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Ival.self, columns: decoded, rowCount: 2)
        #expect(rows == [
            Ival(span: ClickHouseInterval(value: 5, kind: .second)),
            Ival(span: ClickHouseInterval(value: -3, kind: .second))
        ])
    }

    @Test("Every Interval kind round-trips through its type name")
    func intervalKindNames() throws {
        for kind in ClickHouseIntervalKind.allCases {
            #expect(ClickHouseIntervalKind.isKindName(kind.typeName))
            let parsed = try ClickHouseIntervalKind(typeName: kind.typeName)
            #expect(parsed == kind)
        }
    }

    @Test("A non-Interval name is rejected by init(typeName:)")
    func intervalKindRejectsUnknown() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseIntervalKind(typeName: "IntervalFortnight")
        }
    }

    @Test("Nothing column carries its row count and emits one zero byte per row")
    func nothingWire() throws {
        let column: ClickHouseTypedColumn = .nothing(rowCount: 3)
        #expect(column.typeName == "Nothing")
        #expect(column.rowCount == 3)
        // ClickHouse's Native protocol writes one placeholder byte per
        // Nothing row, so a 7-row column is exactly four bytes longer than
        // a 3-row column and the body trails as zero bytes.
        let three = try ClickHouseBlockWriter.encodeDataPacket(
            columns: [ClickHouseNamedColumn(name: "n", column: .nothing(rowCount: 3))],
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        let seven = try ClickHouseBlockWriter.encodeDataPacket(
            columns: [ClickHouseNamedColumn(name: "n", column: .nothing(rowCount: 7))],
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        #expect(seven.count == three.count + 4)
        #expect(Array(three.suffix(3)) == [0, 0, 0])
    }

    @Test("SimpleAggregateFunction strips to its inner wire type")
    func simpleAggregateFunctionExpansion() {
        #expect(ClickHouseGeoTypeName.expand("SimpleAggregateFunction(sum, UInt64)") == "UInt64")
        #expect(ClickHouseGeoTypeName.expand("SimpleAggregateFunction(max, Int32)") == "Int32")
        #expect(
            ClickHouseGeoTypeName.expand("SimpleAggregateFunction(groupArrayArray, Array(UInt64))")
                == "Array(UInt64)"
        )
        #expect(
            ClickHouseGeoTypeName.expand("Array(SimpleAggregateFunction(sum, UInt64))")
                == "Array(UInt64)"
        )
    }
}
