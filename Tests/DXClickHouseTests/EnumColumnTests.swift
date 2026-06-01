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

@Suite("DXClickHouse Enum8 / Enum16 columns")
struct ClickHouseEnumColumnTests {

    static let status: [ClickHouseEnumPair] = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "closed", value: 2),
    ]

    struct Enum8Row: Codable, Sendable, Equatable {
        let status: ClickHouseEnum8
    }

    struct Enum16Row: Codable, Sendable, Equatable {
        let code: ClickHouseEnum16
    }

    @Test("Enum8 renders the full mapping into the type name and one byte per row")
    func encodeEnum8() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Enum8Row(status: ClickHouseEnum8(value: 2, mapping: Self.status)),
            Enum8Row(status: ClickHouseEnum8(value: 1, mapping: Self.status)),
            Enum8Row(status: ClickHouseEnum8(value: 2, mapping: Self.status)),
        ])
        #expect(columns[0].column.typeName == "Enum8('active' = 1, 'closed' = 2)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        #expect(Array(packet.suffix(3)) == [2, 1, 2])
    }

    @Test("Enum16 renders the mapping and writes a little-endian 16-bit ordinal")
    func encodeEnum16() throws {
        let mapping = [
            ClickHouseEnumPair(name: "a", value: 1),
            ClickHouseEnumPair(name: "big", value: 300),
        ]
        let columns = try ClickHouseRowEncoder().encode([
            Enum16Row(code: ClickHouseEnum16(value: 300, mapping: mapping)),
        ])
        #expect(columns[0].column.typeName == "Enum16('a' = 1, 'big' = 300)")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        #expect(Array(packet.suffix(2)) == [0x2C, 0x01])
    }

    @Test("an Enum name containing a comma is rejected with a typed error")
    func rejectsBadName() {
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try ClickHouseRowEncoder().encode([
                Enum8Row(status: ClickHouseEnum8(value: 1, mapping: [ClickHouseEnumPair(name: "a,b", value: 1)])),
            ])
        } catch let error {
            caught = error
        }
        switch caught {
        case .protocolError(let stage, _):
            #expect(stage == "encoder.enum")
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            Issue.record("expected protocolError, got \(caught)")
        }
    }

    @Test("decoder parses the Enum8 mapping back from the type name and reads ordinals")
    func decodeEnum8FromTypeName() throws {
        let body: [UInt8] = [2, 1]
        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["status"],
            columnTypes: ["Enum8('active' = 1, 'closed' = 2)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        switch columns[0].column {
        case .enum8(let values, let mapping):
            #expect(values == [2, 1])
            #expect(mapping == Self.status)
        default:
            Issue.record("expected enum8 column, got \(columns[0].column.typeName)")
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Enum8Row.self, columns: columns, rowCount: 2)
        #expect(rows == [
            Enum8Row(status: ClickHouseEnum8(value: 2, mapping: Self.status)),
            Enum8Row(status: ClickHouseEnum8(value: 1, mapping: Self.status)),
        ])
    }

    @Test("decoder parses negative and multi-digit Enum16 values from the type name")
    func decodeEnum16FromTypeName() throws {
        var body: [UInt8] = []
        withUnsafeBytes(of: Int16(-5).littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(300).littleEndian) { body.append(contentsOf: $0) }
        let block = ClickHouseBlock(
            rowCount: 2, columnCount: 1,
            columnNames: ["code"],
            columnTypes: ["Enum16('neg' = -5, 'big' = 300)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        switch columns[0].column {
        case .enum16(let values, let mapping):
            #expect(values == [-5, 300])
            #expect(mapping == [
                ClickHouseEnumPair(name: "neg", value: -5),
                ClickHouseEnumPair(name: "big", value: 300),
            ])
        default:
            Issue.record("expected enum16 column, got \(columns[0].column.typeName)")
        }
    }
}
