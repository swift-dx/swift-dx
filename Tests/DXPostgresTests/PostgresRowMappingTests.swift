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

@testable import DXPostgres

@Suite struct PostgresRowMappingTests {

    private func column(_ name: String, _ objectID: UInt32 = 25) -> PostgresColumn {
        PostgresColumn(name: name, dataTypeObjectID: objectID, format: .text)
    }

    private func textRow(_ pairs: [(String, String)]) -> PostgresRow {
        PostgresRow(columns: pairs.map { column($0.0) }, cells: pairs.map { .bytes(Array($0.1.utf8)) })
    }

    private struct Widths: Decodable, Equatable {
        let a: Int
        let b: Int8
        let c: Int16
        let d: Int32
        let e: Int64
        let f: UInt
        let g: UInt8
        let h: UInt16
        let i: UInt32
        let j: UInt64
    }

    @Test func decodesStructWithEveryIntegerWidth() throws {
        let row = textRow([("a", "1"), ("b", "2"), ("c", "3"), ("d", "4"), ("e", "5"), ("f", "6"), ("g", "7"), ("h", "8"), ("i", "9"), ("j", "10")])
        #expect(try row.decode(Widths.self) == Widths(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10))
    }

    private struct Scalars: Decodable, Equatable {
        let flag: Bool
        let ratio: Double
        let small: Float
        let label: String
    }

    @Test func decodesStructWithBoolFloatString() throws {
        let row = textRow([("flag", "t"), ("ratio", "2.5"), ("small", "1.25"), ("label", "hi")])
        #expect(try row.decode(Scalars.self) == Scalars(flag: true, ratio: 2.5, small: 1.25, label: "hi"))
    }

    private struct Leaves: Decodable, Equatable {
        let id: UUID
        let when: Date
        let amount: Decimal
    }

    @Test func decodesStructWithUUIDDateDecimalLeaves() throws {
        let row = PostgresRow(
            columns: [column("id", 2950), column("when", 1184), column("amount", 1700)],
            cells: [.bytes(Array("6BA7B810-9DAD-11D1-80B4-00C04FD430C8".utf8)), .bytes(Array("2026-05-31 00:00:00+00".utf8)), .bytes(Array("9.99".utf8))]
        )
        let decoded = try row.decode(Leaves.self)
        #expect(decoded.id == UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        #expect(decoded.amount == Decimal(string: "9.99"))
        #expect(decoded.when.timeIntervalSince1970 > 0)
    }

    @Test func decodesSingleValueColumnForEachWidth() throws {
        #expect(try textRow([("n", "5")]).decode(Int.self) == 5)
        #expect(try textRow([("n", "5")]).decode(Int8.self) == 5)
        #expect(try textRow([("n", "5")]).decode(Int16.self) == 5)
        #expect(try textRow([("n", "5")]).decode(Int32.self) == 5)
        #expect(try textRow([("n", "5")]).decode(Int64.self) == 5)
        #expect(try textRow([("n", "5")]).decode(UInt.self) == 5)
        #expect(try textRow([("n", "5")]).decode(UInt8.self) == 5)
        #expect(try textRow([("n", "5")]).decode(UInt16.self) == 5)
        #expect(try textRow([("n", "5")]).decode(UInt32.self) == 5)
        #expect(try textRow([("n", "5")]).decode(UInt64.self) == 5)
    }

    @Test func decodesSingleValueScalars() throws {
        #expect(try textRow([("v", "t")]).decode(Bool.self) == true)
        #expect(try textRow([("v", "3.5")]).decode(Double.self) == 3.5)
        #expect(try textRow([("v", "1.5")]).decode(Float.self) == 1.5)
        #expect(try textRow([("v", "hello")]).decode(String.self) == "hello")
    }

    @Test func narrowingOverflowThrows() {
        let row = textRow([("n", "100000")])
        #expect(throws: PostgresError.self) {
            try row.decode(Int8.self)
        }
    }

    @Test func missingColumnForStructFieldThrows() {
        struct NeedsTwo: Decodable { let a: Int; let b: Int }
        let row = textRow([("a", "1")])
        #expect(throws: PostgresError.self) {
            try row.decode(NeedsTwo.self)
        }
    }
}
