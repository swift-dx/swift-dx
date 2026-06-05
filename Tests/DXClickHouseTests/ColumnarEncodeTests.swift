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
import Testing

// The columnar fast encode path (ClickHouseColumnarEncodable + the sink) must
// produce exactly the columns the Codable encoder produces. Encoding a batch
// and decoding it back yields the original rows.
@Suite("the ClickHouseColumnarEncodable fast path encodes correctly")
struct ColumnarEncodeTests {

    private struct Row: ClickHouseColumnarEncodable, Decodable, Equatable {
        let id: UInt64; let name: String; let value: Double; let flag: Bool
        static func encodeColumnar(_ rows: [Row], into sink: inout ClickHouseColumnSink) {
            var ids = [UInt64](); var names = [String](); var values = [Double](); var flags = [Bool]()
            for row in rows { ids.append(row.id); names.append(row.name); values.append(row.value); flags.append(row.flag) }
            sink.uint64("id", ids); sink.string("name", names); sink.double("value", values); sink.bool("flag", flags)
        }
    }

    @Test("encodeColumnar produces columns that decode back to the original rows")
    func roundTrips() throws {
        let rows = [
            Row(id: 1, name: "alpha", value: 1.5, flag: true),
            Row(id: 2, name: "", value: -0.25, flag: false),
            Row(id: 3, name: "héllo", value: 1234.5, flag: true),
        ]
        var sink = ClickHouseColumnSink()
        Row.encodeColumnar(rows, into: &sink)
        #expect(sink.columns.map(\.name) == ["id", "name", "value", "flag"])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: sink.columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("the sink matches the Codable encoder column-for-column")
    func matchesCodableEncoder() throws {
        struct CodableRow: Codable, Equatable { let id: UInt64; let name: String; let value: Double; let flag: Bool }
        let fastRows = [Row(id: 10, name: "x", value: 2.0, flag: false), Row(id: 11, name: "y", value: 3.0, flag: true)]
        let codableRows = [CodableRow(id: 10, name: "x", value: 2.0, flag: false), CodableRow(id: 11, name: "y", value: 3.0, flag: true)]
        var sink = ClickHouseColumnSink()
        Row.encodeColumnar(fastRows, into: &sink)
        let codableColumns = try ClickHouseRowEncoder().encode(codableRows)
        // Both decode to identical rows.
        let viaFast = try ClickHouseCodableDecoder.decodeRows(type: CodableRow.self, columns: sink.columns, rowCount: 2)
        let viaCodable = try ClickHouseCodableDecoder.decodeRows(type: CodableRow.self, columns: codableColumns, rowCount: 2)
        #expect(viaFast == viaCodable)
        #expect(viaFast == codableRows)
    }

    @Test("the bytes sink builds a binary-safe String column")
    func bytesColumn() throws {
        struct ByteRow: Decodable, Equatable { let blob: [UInt8] }
        var sink = ClickHouseColumnSink()
        sink.bytes("blob", [[0xFF, 0x00, 0x41], [0x01]])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: ByteRow.self, columns: sink.columns, rowCount: 2)
        #expect(decoded == [ByteRow(blob: [0xFF, 0x00, 0x41]), ByteRow(blob: [0x01])])
    }
}
