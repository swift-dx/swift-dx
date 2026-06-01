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

@Suite("DXClickHouse JSON (String-compatible) column")
struct ClickHouseJSONColumnTests {

    struct Row: Codable, Sendable, Equatable {
        let payload: ClickHouseJSON
    }

    @Test("encoder produces a String-compatible column carrying JSON text bytes")
    func encodesStringCompatibleColumn() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(payload: ClickHouseJSON("{\"a\":1}")),
            Row(payload: ClickHouseJSON(bytes: Array("{\"b\":2}".utf8))),
        ])
        #expect(columns.count == 1)
        #expect(columns[0].name == "payload")
        #expect(columns[0].column.typeName == "String")
        switch columns[0].column {
        case .json(let values):
            #expect(values == [Array("{\"a\":1}".utf8), Array("{\"b\":2}".utf8)])
        default:
            Issue.record("expected a json column, got \(columns[0].column.typeName)")
        }
    }

    @Test("block writer emits UVarInt length prefix followed by the JSON bytes")
    func blockBytesAreLengthPrefixed() throws {
        let text = "{\"a\":1}"
        let columns = try ClickHouseRowEncoder().encode([
            Row(payload: ClickHouseJSON(text)),
        ])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        var expectedBody: [UInt8] = [UInt8(text.utf8.count)]
        expectedBody.append(contentsOf: Array(text.utf8))
        #expect(Array(packet.suffix(expectedBody.count)) == expectedBody)
    }

    @Test("decode lifts a String column body back into JSON text bytes")
    func decodeRoundTrip() throws {
        let columns: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "payload", column: .string(["{\"a\":1}"])),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Row(payload: ClickHouseJSON("{\"a\":1}"))])
    }

    @Test("parseTypedColumns reads a String wire body for a JSON-text field")
    func parseStringWireBody() throws {
        let text = "{\"k\":\"v\"}"
        var body: [UInt8] = [UInt8(text.utf8.count)]
        body.append(contentsOf: Array(text.utf8))
        let block = ClickHouseBlock(
            rowCount: 1,
            columnCount: 1,
            columnNames: ["payload"],
            columnTypes: ["String"],
            bodyStart: 0,
            bodyLength: body.count
        )
        let rows = try body.withUnsafeBytes { rawBuffer -> [Row] in
            let columns = try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: rawBuffer)
            return try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        }
        #expect(rows == [Row(payload: ClickHouseJSON(text))])
    }
}
