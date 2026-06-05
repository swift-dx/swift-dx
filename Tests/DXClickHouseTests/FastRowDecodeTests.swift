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

// The columnar fast path (ClickHouseRowDecodable + ClickHouseColumnBlock) decodes
// the same values as Codable, binds columns by name regardless of result
// order, and surfaces a missing column or a type mismatch as a typed error.
@Suite("the ClickHouseRowDecodable fast path decodes correctly")
struct FastRowDecodeTests {

    private struct Row: ClickHouseRowDecodable, Equatable {
        let id: UInt64; let name: String; let flag: Bool
        static let clickHouseColumnNames = ["id", "name", "flag"]
        init(id: UInt64, name: String, flag: Bool) { self.id = id; self.name = name; self.flag = flag }
        static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [Row] {
            let ids = try block.uint64(0); let names = try block.strings(1); let flags = try block.bool(2)
            return (0..<block.count).map { Row(id: ids[$0], name: names[$0], flag: flags[$0]) }
        }
    }

    private static func columns() -> [ClickHouseNamedColumn] {
        [
            ClickHouseNamedColumn(name: "name", column: .string([Array("a".utf8), Array("b".utf8)])),
            ClickHouseNamedColumn(name: "flag", column: .bool([true, false])),
            ClickHouseNamedColumn(name: "id", column: .uint64([10, 20])),
        ]
    }

    @Test("decodes values and binds by name irrespective of column order")
    func decodesByName() throws {
        let rows = try ClickHouseCodableDecoder.decodeFastRows(type: Row.self, columns: Self.columns(), rowCount: 2)
        #expect(rows == [Row(id: 10, name: "a", flag: true), Row(id: 20, name: "b", flag: false)])
    }

    @Test("an empty result yields no rows")
    func emptyResult() throws {
        let rows = try ClickHouseCodableDecoder.decodeFastRows(type: Row.self, columns: Self.columns(), rowCount: 0)
        #expect(rows.isEmpty)
    }

    @Test("a missing column throws a typed error")
    func missingColumn() {
        let columns = [ClickHouseNamedColumn(name: "id", column: .uint64([1]))]
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseCodableDecoder.decodeFastRows(type: Row.self, columns: columns, rowCount: 1)
        }
    }

    @Test("a type mismatch throws a typed error")
    func typeMismatch() {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .string([Array("x".utf8)])),
            ClickHouseNamedColumn(name: "name", column: .string([Array("a".utf8)])),
            ClickHouseNamedColumn(name: "flag", column: .bool([true])),
        ]
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseCodableDecoder.decodeFastRows(type: Row.self, columns: columns, rowCount: 1)
        }
    }

    @Test("a String column reads losslessly as bytes through the cursor")
    func bytesAccessor() throws {
        struct ByteRow: ClickHouseRowDecodable, Equatable {
            let blob: [UInt8]
            static let clickHouseColumnNames = ["blob"]
            init(blob: [UInt8]) { self.blob = blob }
            static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [ByteRow] {
                let blobs = try block.bytes(0)
                return blobs.map { ByteRow(blob: $0) }
            }
        }
        let binary: [UInt8] = [0xFF, 0x00, 0x41]
        let columns = [ClickHouseNamedColumn(name: "blob", column: .string([binary]))]
        let rows = try ClickHouseCodableDecoder.decodeFastRows(type: ByteRow.self, columns: columns, rowCount: 1)
        #expect(rows == [ByteRow(blob: binary)])
    }
}
