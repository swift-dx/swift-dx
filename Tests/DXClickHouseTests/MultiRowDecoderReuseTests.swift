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

// decodeRows builds one decoder per block and reuses it across every
// row, advancing only the shared row index between rows. This guards
// that the reuse carries no state from one row into the next: each row
// must decode its own column values, including a Nullable column whose
// null/present pattern differs row to row. A decoder that leaked the
// previous row's index or container state would surface here as a
// shifted or repeated value.
@Suite("Reused per-block decoder yields correct independent rows")
struct MultiRowDecoderReuseTests {

    private struct Row: Decodable, Equatable {

        let id: Int32
        let name: String
        let score: Int32?
    }

    @Test("five rows with a mixed null/present Nullable column decode independently")
    func multiRowDecodeIsRowIndependent() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .int32([10, 20, 30, 40, 50])),
            ClickHouseNamedColumn(name: "name", column: .string([Array("a".utf8), Array("b".utf8), Array("c".utf8), Array("d".utf8), Array("e".utf8)])),
            ClickHouseNamedColumn(name: "score", column: .nullableInt32([
                .present(1), .absent, .present(3), .absent, .present(5),
            ])),
        ]

        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 5)

        #expect(rows == [
            Row(id: 10, name: "a", score: 1),
            Row(id: 20, name: "b", score: nil),
            Row(id: 30, name: "c", score: 3),
            Row(id: 40, name: "d", score: nil),
            Row(id: 50, name: "e", score: 5),
        ])
    }

    @Test("a single-row block still decodes through the reused-decoder path")
    func singleRowDecodes() throws {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .int32([7])),
            ClickHouseNamedColumn(name: "name", column: .string([Array("only".utf8)])),
            ClickHouseNamedColumn(name: "score", column: .nullableInt32([.absent])),
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Row(id: 7, name: "only", score: nil)])
    }
}
