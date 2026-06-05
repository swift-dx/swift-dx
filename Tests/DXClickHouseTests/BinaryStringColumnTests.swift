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

// A ClickHouse String column is an arbitrary byte sequence. The typed column
// now carries the raw bytes, so a [UInt8] field reads them losslessly while a
// String field still gets the UTF-8 interpretation. Binary payloads stored in
// a String column are no longer corrupted on the way out.
@Suite("a String column exposes its exact bytes through a [UInt8] field")
struct BinaryStringColumnTests {

    private struct BytesRow: Decodable { let b: [UInt8] }
    private struct StringRow: Decodable { let b: String }

    @Test("binary bytes (invalid UTF-8) round-trip through a [UInt8] field")
    func binaryRoundTrips() throws {
        let binary: [UInt8] = [0xFF, 0x00, 0xFE, 0x80, 0x41]
        let column = ClickHouseNamedColumn(name: "b", column: .string([binary]))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: BytesRow.self, columns: [column], rowCount: 1)
        #expect(rows[0].b == binary)
    }

    @Test("valid UTF-8 decodes the same through both String and [UInt8]")
    func validUtf8BothPaths() throws {
        let text = "héllo"
        let bytes = Array(text.utf8)
        let column = ClickHouseNamedColumn(name: "b", column: .string([bytes]))
        let asString = try ClickHouseCodableDecoder.decodeRows(type: StringRow.self, columns: [column], rowCount: 1)
        let asBytes = try ClickHouseCodableDecoder.decodeRows(type: BytesRow.self, columns: [column], rowCount: 1)
        #expect(asString[0].b == text)
        #expect(asBytes[0].b == bytes)
    }

    @Test("an Array(UInt8) column still decodes through the native-array path")
    func arrayUInt8Unaffected() throws {
        let column = ClickHouseNamedColumn(name: "b", column: .array([[[10], [20], [30]]], element: .uint8))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: BytesRow.self, columns: [column], rowCount: 1)
        #expect(rows[0].b == [10, 20, 30])
    }

    @Test("a String field still round-trips a normal string through encode and decode")
    func stringRoundTrips() throws {
        struct Row: Codable, Equatable { let b: String }
        let columns = try ClickHouseRowEncoder().encode([Row(b: "alpha"), Row(b: "")])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 2)
        #expect(decoded == [Row(b: "alpha"), Row(b: "")])
    }

    @Test("a Nullable(String) column exposes present bytes and nil through a [UInt8]? field")
    func nullableBinaryRoundTrips() throws {
        struct OptRow: Decodable { let b: [UInt8]? }
        let binary: [UInt8] = [0xFF, 0x00, 0x80]
        let column = ClickHouseNamedColumn(name: "b", column: .nullableString([.present(binary), .absent, .present([0x41])]))
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptRow.self, columns: [column], rowCount: 3)
        #expect(rows[0].b == binary)
        #expect(rows[1].b == nil)
        #expect(rows[2].b == [0x41])
    }
}
