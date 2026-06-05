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

// ClickHouseQueryResult reads any query's columns by name and row with no
// Codable type. It spans multiple result blocks transparently and surfaces a
// missing column, a type mismatch, or an out-of-range row as a typed error.
@Suite("ClickHouseQueryResult reads columns by name across blocks")
struct QueryResultTests {

    private static func twoBlockResult() -> ClickHouseQueryResult {
        let block0: [ClickHouseTypedColumn] = [.uint64([1, 2]), .string([Array("a".utf8), Array("b".utf8)])]
        let block1: [ClickHouseTypedColumn] = [.uint64([3]), .string([Array("c".utf8)])]
        return ClickHouseQueryResult(
            columnNames: ["id", "name"],
            columnTypes: ["UInt64", "String"],
            rowCount: 3,
            blocks: [block0, block1],
            blockOffsets: [0, 2, 3]
        )
    }

    @Test("reads scalar and string columns spanning a block boundary")
    func readsAcrossBlocks() throws {
        let result = Self.twoBlockResult()
        #expect(result.rowCount == 3)
        #expect(result.columnNames == ["id", "name"])
        #expect(try result.uint64("id", 0) == 1)
        #expect(try result.uint64("id", 1) == 2)
        #expect(try result.uint64("id", 2) == 3)        // second block, local row 0
        #expect(try result.string("name", 0) == "a")
        #expect(try result.string("name", 2) == "c")    // second block
        #expect(try result.bytes("name", 2) == Array("c".utf8))
    }

    @Test("a missing column throws a typed error")
    func missingColumn() {
        let result = Self.twoBlockResult()
        #expect(throws: ClickHouseError.self) { _ = try result.uint64("nope", 0) }
    }

    @Test("a wrong-type read throws a typed error")
    func typeMismatch() {
        let result = Self.twoBlockResult()
        #expect(throws: ClickHouseError.self) { _ = try result.string("id", 0) }
        #expect(throws: ClickHouseError.self) { _ = try result.uint64("name", 0) }
    }

    @Test("an out-of-range row throws a typed error")
    func rowOutOfRange() {
        let result = Self.twoBlockResult()
        #expect(throws: ClickHouseError.self) { _ = try result.uint64("id", 3) }
        #expect(throws: ClickHouseError.self) { _ = try result.uint64("id", -1) }
    }

    @Test("reads a Nullable column, detects NULL, and throws when reading a NULL value")
    func nullableColumn() throws {
        let block: [ClickHouseTypedColumn] = [
            .nullableUInt64([.present(7), .absent]),
            .uint8([5, 6]),
        ]
        let result = ClickHouseQueryResult(
            columnNames: ["n", "s"], columnTypes: ["Nullable(UInt64)", "UInt8"],
            rowCount: 2, blocks: [block], blockOffsets: [0, 2]
        )
        #expect(try result.isNull("n", 0) == false)
        #expect(try result.isNull("n", 1) == true)
        #expect(try result.isNull("s", 0) == false)   // non-nullable is never NULL
        #expect(try result.uint64("n", 0) == 7)
        #expect(try result.uint8("s", 1) == 6)
        #expect(throws: ClickHouseError.self) { _ = try result.uint64("n", 1) }  // reading a NULL throws
    }

    @Test("reads DateTime, UUID, and Decimal columns")
    func widerTypes() throws {
        let instant = Date(timeIntervalSince1970: 1_780_000_000)
        let identifier = UUID()
        let amount = try ClickHouseDecimal("123.45", precision: 9, scale: 2)
        let block: [ClickHouseTypedColumn] = [
            .dateTime([instant]),
            .uuid([identifier]),
            .decimal([amount], precision: 9, scale: 2),
        ]
        let result = ClickHouseQueryResult(
            columnNames: ["ts", "u", "d"], columnTypes: ["DateTime", "UUID", "Decimal(9, 2)"],
            rowCount: 1, blocks: [block], blockOffsets: [0, 1]
        )
        #expect(try result.date("ts", 0) == instant)
        #expect(try result.uuid("u", 0) == identifier)
        #expect(try result.decimal("d", 0) == amount)
    }

    @Test("reads Array(String) and Array(Int64) columns per row")
    func arrayColumns() throws {
        func le(_ value: Int64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let block: [ClickHouseTypedColumn] = [
            .array([[Array("a".utf8), Array("b".utf8)], [Array("c".utf8)]], element: .string),
            .array([[le(-1), le(2)], [le(7)]], element: .int64),
        ]
        let result = ClickHouseQueryResult(
            columnNames: ["tags", "ints"], columnTypes: ["Array(String)", "Array(Int64)"],
            rowCount: 2, blocks: [block], blockOffsets: [0, 2]
        )
        #expect(try result.stringArray("tags", 0) == ["a", "b"])
        #expect(try result.stringArray("tags", 1) == ["c"])
        #expect(try result.int64Array("ints", 0) == [-1, 2])
        #expect(try result.int64Array("ints", 1) == [7])
        #expect(throws: ClickHouseError.self) { _ = try result.int64Array("tags", 0) }  // wrong element type
    }
}
