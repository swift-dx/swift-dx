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

import Testing
@testable import DXClickHouse

@Suite("ClickHouseStringView")
struct ClickHouseStringViewTests {

    // Arena layout matches the wire-decoder shape: payload bytes
    // packed contiguously with an offsets index of length rows + 1.
    // Building views by hand here lets the tests exercise the view
    // surface without standing up a SELECT round-trip.
    private static func makeArenaColumn(_ rows: [String]) -> ClickHouseStringColumnView {
        var arena: [UInt8] = []
        var offsets: [Int] = [0]
        for row in rows {
            arena.append(contentsOf: Array(row.utf8))
            offsets.append(arena.count)
        }
        let handle = ClickHouseStringArena(bytes: arena)
        return ClickHouseStringColumnView(name: "col", arena: handle, offsets: offsets)
    }

    @Test("a fresh arena column reports its row count and rebuilds every payload byte for byte")
    func roundTripBytes() {
        let rows = ["", "hello", "world", "café", "🚀"]
        let column = Self.makeArenaColumn(rows)
        #expect(column.rowCount == rows.count)
        for index in 0..<rows.count {
            let view = column.view(at: index)
            #expect(view.utf8Length == Array(rows[index].utf8).count)
            #expect(view.asString() == rows[index])
        }
    }

    @Test("withUTF8Bytes hands the caller a buffer that matches the payload byte for byte")
    func zeroCopyBytes() {
        let column = Self.makeArenaColumn(["abc", "defg", "hijkl"])
        let payloads = ["abc", "defg", "hijkl"]
        for index in 0..<payloads.count {
            let view = column.view(at: index)
            let expected = Array(payloads[index].utf8)
            let observed: [UInt8] = view.withUTF8Bytes { buffer in
                Array(buffer)
            }
            #expect(observed == expected)
        }
    }

    @Test("view-vs-view equality is byte-for-byte and ignores identity")
    func viewVsViewEquality() {
        let a = Self.makeArenaColumn(["abc"])
        let b = Self.makeArenaColumn(["abc"])
        let c = Self.makeArenaColumn(["abd"])
        #expect(a.view(at: 0) == b.view(at: 0))
        #expect(!(a.view(at: 0) == c.view(at: 0)))
    }

    @Test("view-vs-string equality skips materialisation and matches on byte content")
    func viewVsStringEquality() {
        let column = Self.makeArenaColumn(["hello", ""])
        let nonEmpty = column.view(at: 0)
        let empty = column.view(at: 1)
        #expect(nonEmpty == "hello")
        #expect("hello" == nonEmpty)
        #expect(!(nonEmpty == "world"))
        #expect(!(nonEmpty == "hell"))
        #expect(empty == "")
        #expect("" == empty)
        #expect(!(empty == "x"))
    }

    @Test("hashing two views with the same bytes produces the same hash value")
    func hashStability() {
        let a = Self.makeArenaColumn(["payload"])
        let b = Self.makeArenaColumn(["payload"])
        var hasherA = Hasher()
        a.view(at: 0).hash(into: &hasherA)
        var hasherB = Hasher()
        b.view(at: 0).hash(into: &hasherB)
        #expect(hasherA.finalize() == hasherB.finalize())
    }

    @Test("the arena outlives the producing column when at least one view still references it")
    func arenaSurvivesColumnRelease() {
        let view: ClickHouseStringView = {
            let column = Self.makeArenaColumn(["surviving payload"])
            return column.view(at: 0)
        }()
        #expect(view == "surviving payload")
        #expect(view.utf8Length == Array("surviving payload".utf8).count)
    }

    @Test("materialiseStrings reproduces the eager [String] form of the column")
    func materialiseAll() {
        let rows = ["alpha", "beta", "", "gamma"]
        let column = Self.makeArenaColumn(rows)
        #expect(column.materialiseStrings() == rows)
    }

    @Test("an empty arena reports zero rows and rejects no lookup because there are none")
    func emptyColumn() {
        let column = Self.makeArenaColumn([])
        #expect(column.rowCount == 0)
        #expect(column.materialiseStrings() == [])
    }

    @Test("the legacy String-column decode path still vends the arena-backed view")
    func decodedStringColumnExposesView() throws {
        let column = ClickHouseStringColumn(
            spec: .string,
            deferredArena: Array("hellothere".utf8),
            offsets: [0, 5, 10]
        )
        #expect(column.hasArena)
        let viewZero = column.stringView(at: 0)
        let viewOne = column.stringView(at: 1)
        #expect(viewZero == "hello")
        #expect(viewOne == "there")
        #expect(column.values == ["hello", "there"])
    }

    @Test("the eager String-column path reports no arena because there is no wire buffer to borrow")
    func eagerStringColumnReportsNoArena() {
        let column = ClickHouseStringColumn(spec: .string, values: ["x", "y"])
        #expect(!column.hasArena)
        #expect(column.values == ["x", "y"])
    }

}
