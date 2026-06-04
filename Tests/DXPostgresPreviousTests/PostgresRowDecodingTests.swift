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

import Foundation
import Testing

@testable import DXPostgresPrevious

@Suite struct PostgresRowDecodingTests {

    private func column(_ name: String, _ objectID: UInt32) -> PostgresColumn {
        PostgresColumn(name: name, dataTypeObjectID: objectID, format: .text)
    }

    private func makeRow() -> PostgresRow {
        let columns = [
            column("count", 23),
            column("label", 25),
            column("ratio", 701),
            column("flag", 16),
            column("token", 2950),
            column("payload", 17),
            column("missing", 25),
        ]
        let cells: [PostgresCell] = [
            .bytes(Array("42".utf8)),
            .bytes(Array("hello".utf8)),
            .bytes(Array("3.5".utf8)),
            .bytes(Array("t".utf8)),
            .bytes(Array("6BA7B810-9DAD-11D1-80B4-00C04FD430C8".utf8)),
            .bytes(Array("\\xdeadbeef".utf8)),
            .sqlNull,
        ]
        return PostgresRow(columns: columns, cells: cells)
    }

    @Test func decodesScalarsByIndexAndName() throws {
        let row = makeRow()
        #expect(try row.decode(Int.self, at: 0) == 42)
        #expect(try row.decode(String.self, named: "label") == "hello")
        #expect(try row.decode(Double.self, named: "ratio") == 3.5)
        #expect(try row.decode(Bool.self, named: "flag") == true)
    }

    @Test func decodesUUIDAndBytea() throws {
        let row = makeRow()
        #expect(try row.decode(UUID.self, named: "token") == UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        #expect(try row.decode([UInt8].self, named: "payload") == [0xde, 0xad, 0xbe, 0xef])
    }

    @Test func nullableColumnDecodesToSqlNull() throws {
        let row = makeRow()
        #expect(try row.decodeNullable(String.self, named: "missing") == .sqlNull)
        #expect(try row.decodeNullable(Int.self, at: 0) == .value(42))
    }

    @Test func nonNullableNullColumnThrows() {
        let row = makeRow()
        #expect(throws: PostgresError.self) {
            try row.decode(String.self, named: "missing")
        }
    }

    @Test func outOfRangeIndexThrows() {
        let row = makeRow()
        #expect(throws: PostgresError.self) {
            try row.decode(Int.self, at: 99)
        }
    }

    @Test func unknownColumnNameThrows() {
        let row = makeRow()
        #expect(throws: PostgresError.self) {
            try row.decode(Int.self, named: "nope")
        }
    }

    @Test func malformedIntegerTextThrows() {
        let row = PostgresRow(columns: [column("count", 23)], cells: [.bytes(Array("not-a-number".utf8))])
        #expect(throws: PostgresError.self) {
            try row.decode(Int.self, at: 0)
        }
    }

    @Test func columnReportsNamedDataType() {
        #expect(column("count", 23).dataType == .int4)
        #expect(column("token", 2950).dataType == .uuid)
        #expect(column("custom", 999999).dataType == .other(objectID: 999999))
    }
}
