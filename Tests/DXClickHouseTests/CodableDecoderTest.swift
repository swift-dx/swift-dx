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

@Suite("DXClickHouse Codable decoder")
struct ClickHouseColumnarDecoderTest {

    struct Row: Codable, Sendable, Equatable {
        let id: UInt64
        let name: String
        let score: Double
    }

    struct OptRow: Codable, Sendable, Equatable {
        let id: UInt64
        let label: String?
        let count: Int32?
    }

    @Test("Decoder materializes a row from typed columnar storage in declaration order")
    func decodesBasicRows() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64([100, 200])),
            ClickHouseNamedColumn(name: "name", column: .string([Array("alpha".utf8), Array("beta".utf8)])),
            ClickHouseNamedColumn(name: "score", column: .float64([1.5, 2.5])),
        ]
        let rows: [Row] = try ClickHouseCodableDecoder.decodeRows(
            type: Row.self,
            columns: columns,
            rowCount: 2
        )
        #expect(rows == [
            Row(id: 100, name: "alpha", score: 1.5),
            Row(id: 200, name: "beta", score: 2.5),
        ])
    }

    @Test("Decoder maps Nullable columns to Optional<T> fields")
    func decodesNullableColumns() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64([1, 2])),
            ClickHouseNamedColumn(name: "label", column: .nullableString([.present(Array("hello".utf8)), .absent])),
            ClickHouseNamedColumn(name: "count", column: .nullableInt32([.present(42), .absent])),
        ]
        let rows: [OptRow] = try ClickHouseCodableDecoder.decodeRows(
            type: OptRow.self,
            columns: columns,
            rowCount: 2
        )
        #expect(rows == [
            OptRow(id: 1, label: "hello", count: 42),
            OptRow(id: 2, label: nil, count: nil),
        ])
    }

    @Test("Decoder surfaces missing column as DecodingError.keyNotFound")
    func missingColumnError() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64([1])),
        ]
        let caught = captureDecoderError {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        }
        switch caught {
        case .some(let error):
            switch error {
            case .protocolError(_, let message):
                #expect(message.contains("decode failed"))
            default:
                Issue.record("expected protocolError, got \(error)")
            }
        case .none:
            Issue.record("expected decoder to fail")
        }
    }

    @Test("Decoder surfaces NULL→non-Optional mismatch as a typed error")
    func nullIntoNonOptional() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64([1])),
            ClickHouseNamedColumn(name: "name", column: .nullableString([.absent])),
            ClickHouseNamedColumn(name: "score", column: .float64([1.0])),
        ]
        let caught = captureDecoderError {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        }
        switch caught {
        case .some(let error):
            switch error {
            case .protocolError: break
            default: Issue.record("expected protocolError, got \(error)")
            }
        case .none:
            Issue.record("expected decoder to fail")
        }
    }

    private func captureDecoderError(_ body: () throws -> Void) -> ClickHouseError? {
        do {
            try body()
            return nil
        } catch let error as ClickHouseError {
            return error
        } catch {
            return nil
        }
    }
}

@Suite("DXClickHouse block writer + decoder round-trip")
struct ClickHouseBlockRoundTripTest {

    struct Row: Codable, Sendable, Equatable {
        let id: UInt64
        let name: String
        let score: Double
        let active: Bool
    }

    struct DateRow: Codable, Sendable, Equatable {
        let id: UInt32
        let timestamp: Date
    }

    @Test("Writer + parser preserve scalar columns end-to-end")
    func scalarRoundTrip() throws {
        let encoder = ClickHouseRowEncoder()
        let inputRows = [
            Row(id: 1, name: "alpha", score: 1.5, active: true),
            Row(id: 2, name: "beta with spaces", score: -2.5, active: false),
            Row(id: 3, name: "", score: 0, active: true),
        ]
        let columns = try encoder.encode(inputRows)
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: 54_478)
        // The block body the decoder consumes starts AFTER the
        // Data-packet header (packet type, table name, BlockInfo,
        // columnCount, rowCount, per-column header + flag). Drop the
        // outer Data framing here so we can drive the decoder against
        // just the column-body bytes. Strip by re-parsing the packet
        // and reconstructing the column buffers directly.
        let parsed = try Self.parseEncodedDataPacket(dataPacket)
        let recovered: [Row] = try ClickHouseCodableDecoder.decodeRows(
            type: Row.self, columns: parsed, rowCount: inputRows.count
        )
        #expect(recovered == inputRows)
    }

    @Test("Writer + parser preserve Date column with second precision")
    func dateRoundTrip() throws {
        let encoder = ClickHouseRowEncoder()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let inputRows = [
            DateRow(id: 1, timestamp: base),
            DateRow(id: 2, timestamp: base.addingTimeInterval(60)),
        ]
        let columns = try encoder.encode(inputRows)
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: 54_478)
        let parsed = try Self.parseEncodedDataPacket(dataPacket)
        let recovered: [DateRow] = try ClickHouseCodableDecoder.decodeRows(
            type: DateRow.self, columns: parsed, rowCount: inputRows.count
        )
        #expect(recovered == inputRows)
    }

    @Test("Writer + parser preserve UUID column")
    func uuidRoundTrip() throws {
        struct UUIDRow: Codable, Sendable, Equatable {
            let id: UInt32
            let uuid: UUID
        }
        let inputRows = [
            UUIDRow(id: 1, uuid: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!),
            UUIDRow(id: 2, uuid: UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!),
        ]
        let columns = try ClickHouseRowEncoder().encode(inputRows)
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: 54_478)
        let parsed = try Self.parseEncodedDataPacket(dataPacket)
        let recovered: [UUIDRow] = try ClickHouseCodableDecoder.decodeRows(
            type: UUIDRow.self, columns: parsed, rowCount: inputRows.count
        )
        #expect(recovered == inputRows)
    }

    @Test("Writer + parser preserve Nullable(String) and Nullable(Int64) end-to-end")
    func nullableRoundTrip() throws {
        struct NRow: Codable, Sendable, Equatable {
            let id: UInt32
            let label: String?
            let count: Int64?
        }
        let inputRows = [
            NRow(id: 1, label: "first", count: 100),
            NRow(id: 2, label: nil, count: nil),
            NRow(id: 3, label: "third", count: -42),
        ]
        let columns = try ClickHouseRowEncoder().encode(inputRows)
        let dataPacket = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: 54_478)
        let parsed = try Self.parseEncodedDataPacket(dataPacket)
        let recovered: [NRow] = try ClickHouseCodableDecoder.decodeRows(
            type: NRow.self, columns: parsed, rowCount: inputRows.count
        )
        #expect(recovered == inputRows)
    }

    // Parses a Data packet emitted by ClickHouseBlockWriter and
    // reconstructs the per-column body slices in the layout the wire
    // transport delivers to ClickHouseCodableDecoder.parseTypedColumns.
    static func parseEncodedDataPacket(_ packet: [UInt8]) throws -> [ClickHouseNamedColumn] {
        var cursor = 0
        let (packetType, packetTypeBytes) = try packet.withUnsafeBufferPointer { buffer in
            try ClickHouseWire.readUVarInt(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
        }
        cursor += packetTypeBytes
        #expect(packetType == 2)
        let tableName = try packet.withUnsafeBufferPointer { buffer in
            try ClickHouseWire.readString(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
        }
        cursor += tableName.1
        // BlockInfo: field 1 (UVarInt) + bool (1 byte) + field 2 (UVarInt) + int32 (4 bytes) + terminator (UVarInt 0)
        cursor += try advanceBlockInfo(packet: packet, offset: cursor)
        let (columnCount, ccBytes) = try packet.withUnsafeBufferPointer { buffer in
            try ClickHouseWire.readUVarInt(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
        }
        cursor += ccBytes
        let (rowCount, rcBytes) = try packet.withUnsafeBufferPointer { buffer in
            try ClickHouseWire.readUVarInt(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
        }
        cursor += rcBytes
        var combinedBody: [UInt8] = []
        var combinedColumns: [(name: String, type: String, start: Int)] = []
        for _ in 0..<Int(columnCount) {
            let nameParse = try packet.withUnsafeBufferPointer { buffer in
                try ClickHouseWire.readString(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
            }
            cursor += nameParse.1
            let typeParse = try packet.withUnsafeBufferPointer { buffer in
                try ClickHouseWire.readString(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
            }
            cursor += typeParse.1
            cursor += 1 // hasCustomSerialization byte
            let start = combinedBody.count
            let bodyLength = try Self.columnBodyLength(type: typeParse.0, rowCount: Int(rowCount), packet: packet, offset: cursor)
            combinedBody.append(contentsOf: packet[cursor..<cursor + bodyLength])
            cursor += bodyLength
            combinedColumns.append((nameParse.0, typeParse.0, start))
        }
        // We have raw body bytes per column appended together — emulate
        // the layout `parseTypedColumns` expects. Reuse the existing
        // parser by going through `ClickHouseBlock` synthesis.
        let block = ClickHouseBlock(
            rowCount: Int(rowCount),
            columnCount: Int(columnCount),
            columnNames: combinedColumns.map(\.name),
            columnTypes: combinedColumns.map(\.type),
            bodyStart: 0,
            bodyLength: combinedBody.count
        )
        return try combinedBody.withUnsafeBytes { rawBuffer in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: rawBuffer)
        }
    }

    private static func advanceBlockInfo(packet: [UInt8], offset: Int) throws -> Int {
        var cursor = offset
        while true {
            let (field, bytes) = try packet.withUnsafeBufferPointer { buffer in
                try ClickHouseWire.readUVarInt(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
            }
            cursor += bytes
            switch field {
            case 0: return cursor - offset
            case 1: cursor += 1
            case 2: cursor += 4
            default: throw ClickHouseError.protocolError(stage: "blockInfo", message: "unknown field \(field)")
            }
        }
    }

    // Mirrors what the connection's skipColumnBody walks for the
    // supported types in this test. Only covers the types the writer
    // emits in the round-trip suite above.
    static func columnBodyLength(type: String, rowCount: Int, packet: [UInt8], offset: Int) throws -> Int {
        if type.hasPrefix("Nullable(") {
            let inner = String(type.dropFirst("Nullable(".count).dropLast())
            let innerOffset = offset + rowCount
            let innerLength = try columnBodyLength(type: inner, rowCount: rowCount, packet: packet, offset: innerOffset)
            return rowCount + innerLength
        }
        switch type {
        case "Bool", "Int8", "UInt8": return rowCount
        case "Int16", "UInt16": return rowCount * 2
        case "Int32", "UInt32", "Float32", "DateTime": return rowCount * 4
        case "Int64", "UInt64", "Float64": return rowCount * 8
        case "UUID": return rowCount * 16
        case "String":
            var cursor = offset
            for _ in 0..<rowCount {
                let parsed = try packet.withUnsafeBufferPointer { buffer in
                    try ClickHouseWire.readString(base: buffer.baseAddress!, offset: cursor, limit: packet.count)
                }
                cursor += parsed.1
            }
            return cursor - offset
        default:
            throw ClickHouseError.protocolError(stage: "columnBodyLength", message: "unsupported \(type)")
        }
    }
}
