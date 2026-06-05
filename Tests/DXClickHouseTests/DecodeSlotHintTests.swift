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

// decodeIfPresent resolves a field's column slot once and hands it to the
// inner decode via a one-shot hint, avoiding a second column-name hash. The
// hint must never leak to the next field: a row with several optional and
// non-optional columns interleaved, each holding distinct values, would
// surface a leaked slot as a wrong value or a type mismatch. These guard
// that the optimization preserves the exact decoded output.
@Suite("Slot-hint decode preserves correct per-field values")
struct DecodeSlotHintTests {

    private struct Row: Decodable, Equatable {
        let a: Int32?
        let b: String
        let c: Int64?
        let d: Int32
        let e: String?
    }

    @Test("interleaved optional and non-optional columns decode to their own values")
    func interleavedFields() throws {
        let columns = [
            ClickHouseNamedColumn(name: "a", column: .nullableInt32([.present(10), .absent, .present(30)])),
            ClickHouseNamedColumn(name: "b", column: .string([Array("b0".utf8), Array("b1".utf8), Array("b2".utf8)])),
            ClickHouseNamedColumn(name: "c", column: .nullableInt64([.absent, .present(201), .present(202)])),
            ClickHouseNamedColumn(name: "d", column: .int32([40, 41, 42])),
            ClickHouseNamedColumn(name: "e", column: .nullableString([.present(Array("e0".utf8)), .present(Array("e1".utf8)), .absent])),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 3)
        #expect(rows == [
            Row(a: 10, b: "b0", c: nil, d: 40, e: "e0"),
            Row(a: nil, b: "b1", c: 201, d: 41, e: "e1"),
            Row(a: 30, b: "b2", c: 202, d: 42, e: nil),
        ])
    }

    @Test("two adjacent optional columns do not cross their resolved slots")
    func adjacentOptionals() throws {
        struct TwoOpt: Decodable, Equatable {
            let first: Int32?
            let second: Int64?
        }
        let columns = [
            ClickHouseNamedColumn(name: "first", column: .nullableInt32([.present(7)])),
            ClickHouseNamedColumn(name: "second", column: .nullableInt64([.present(9_000_000_000)])),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: TwoOpt.self, columns: columns, rowCount: 1)
        #expect(rows == [TwoOpt(first: 7, second: 9_000_000_000)])
    }
}
