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

// A Swift enum is the idiomatic way to model a status / category column.
// Decoding a row whose field is a RawRepresentable Codable enum runs the
// container's generic decode<T> with T = the enum, which previously failed
// with "Unsupported Swift decode target". The container now delegates such
// a target to its own init(from:) over a single-value view of the column,
// so the enum reads its RawValue (Int32, String, …) through the validated
// typed-decode path.
@Suite("Swift enum fields decode from their underlying column")
struct EnumFieldDecodeTests {

    private enum Status: Int32, Codable, Equatable { case active = 1, closed = 2, pending = 7 }
    private enum Color: String, Codable, Equatable { case red, green, blue }

    private struct IntEnumRow: Decodable, Equatable { let status: Status }
    private struct StringEnumRow: Decodable, Equatable { let color: Color }
    private struct OptionalEnumRow: Decodable, Equatable { let status: Status? }

    @Test("an Int32-backed enum decodes from an Int32 column")
    func intBackedEnum() throws {
        let columns = [ClickHouseNamedColumn(name: "status", column: .int32([1, 7, 2]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: IntEnumRow.self, columns: columns, rowCount: 3)
        #expect(rows.map(\.status) == [.active, .pending, .closed])
    }

    @Test("a String-backed enum decodes from a String column")
    func stringBackedEnum() throws {
        let columns = [ClickHouseNamedColumn(name: "color", column: .string([Array("green".utf8), Array("red".utf8), Array("blue".utf8)]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: StringEnumRow.self, columns: columns, rowCount: 3)
        #expect(rows.map(\.color) == [.green, .red, .blue])
    }

    @Test("an optional enum decodes present and null values")
    func optionalEnum() throws {
        let columns = [ClickHouseNamedColumn(name: "status", column: .nullableInt32([.present(2), .absent]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptionalEnumRow.self, columns: columns, rowCount: 2)
        #expect(rows[0].status == .closed)
        #expect(rows[1].status == nil)
    }

    @Test("a column value with no matching enum case surfaces a typed decode error")
    func unmappedValueThrows() {
        let columns = [ClickHouseNamedColumn(name: "status", column: .int32([999]))]
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: IntEnumRow.self, columns: columns, rowCount: 1)
        }
    }
}
