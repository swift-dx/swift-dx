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
@testable import DXClickHouse

@Suite("ClickHouseFixedStringView")
struct ClickHouseFixedStringViewTests {

    // Arena layout matches the wire-decoder shape: contiguous N-byte
    // rows packed in a single `[UInt8]` with no varint header.
    private static func makeArenaColumn(_ rows: [String], width: Int) -> ClickHouseFixedStringColumnView {
        var arena: [UInt8] = []
        arena.reserveCapacity(rows.count * width)
        for row in rows {
            var bytes = Array(row.utf8)
            if bytes.count < width {
                bytes.append(contentsOf: Array(repeating: UInt8(0), count: width - bytes.count))
            }
            arena.append(contentsOf: bytes)
        }
        let handle = ClickHouseFixedStringArena(bytes: arena, fixedWidth: width)
        return ClickHouseFixedStringColumnView(name: "col", arena: handle)
    }

    @Test("rows can be addressed by index and report the configured fixed width")
    func roundTripWidth() {
        let rows = ["abcd", "efgh", "ijkl"]
        let column = Self.makeArenaColumn(rows, width: 4)
        #expect(column.rowCount == 3)
        #expect(column.fixedWidth == 4)
        for index in 0..<rows.count {
            let view = column.view(at: index)
            #expect(view.byteCount == 4)
            #expect(view.asString() == rows[index])
        }
    }

    @Test("withBytes hands the caller a buffer that matches the payload byte for byte")
    func zeroCopyBytes() {
        let rows = ["AAAA", "BBBB", "CCCC"]
        let column = Self.makeArenaColumn(rows, width: 4)
        for index in 0..<rows.count {
            let view = column.view(at: index)
            let expected = Array(rows[index].utf8)
            let observed: [UInt8] = view.withBytes { buffer in Array(buffer) }
            #expect(observed == expected)
        }
    }

    @Test("view-vs-view equality is byte-for-byte and ignores identity")
    func viewVsViewEquality() {
        let a = Self.makeArenaColumn(["abc-"], width: 4)
        let b = Self.makeArenaColumn(["abc-"], width: 4)
        let c = Self.makeArenaColumn(["xyz-"], width: 4)
        #expect(a.view(at: 0) == b.view(at: 0))
        #expect(!(a.view(at: 0) == c.view(at: 0)))
    }

    @Test("view-vs-string equality skips materialisation and matches on byte content")
    func viewVsStringEquality() {
        let column = Self.makeArenaColumn(["pass"], width: 4)
        let view = column.view(at: 0)
        #expect(view == "pass")
        #expect("pass" == view)
        #expect(!(view == "fail"))
        #expect(!(view == "passing"))
    }

    @Test("hashing two views with the same bytes produces the same hash value")
    func hashStability() {
        let a = Self.makeArenaColumn(["xx"], width: 2)
        let b = Self.makeArenaColumn(["xx"], width: 2)
        var hasherA = Hasher()
        a.view(at: 0).hash(into: &hasherA)
        var hasherB = Hasher()
        b.view(at: 0).hash(into: &hasherB)
        #expect(hasherA.finalize() == hasherB.finalize())
    }

    @Test("the arena outlives the producing column when at least one view still references it")
    func arenaSurvivesColumnRelease() {
        let view: ClickHouseFixedStringView = {
            let column = Self.makeArenaColumn(["keep"], width: 4)
            return column.view(at: 0)
        }()
        #expect(view == "keep")
        #expect(view.byteCount == 4)
    }

    @Test("materialiseStrings reproduces the eager [String] form of the column")
    func materialiseAll() {
        let rows = ["zzz", "yyy", "xxx"]
        let column = Self.makeArenaColumn(rows, width: 3)
        #expect(column.materialiseStrings() == rows)
    }

    @Test("the FixedString decode path exposes the arena-backed view")
    func decodedFixedStringExposesView() throws {
        let length = 4
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: length),
            length: length,
            deferredArena: Array("hellworld".utf8) + Array(repeating: UInt8(0), count: length - 1)
        )
        // Above bytes: "hellworld\0\0\0" = 12 bytes / 4 = 3 rows.
        #expect(column.hasArena)
        #expect(column.rowCount == 3)
        let viewZero = column.fixedStringView(at: 0)
        let viewOne = column.fixedStringView(at: 1)
        let viewTwo = column.fixedStringView(at: 2)
        #expect(viewZero == "hell")
        #expect(viewOne == "worl")
        #expect(viewTwo.withBytes { buffer -> [UInt8] in Array(buffer) } == Array("d\0\0\0".utf8))
        #expect(column.values.count == 3)
    }

    @Test("the eager FixedString-column path reports no arena because there is no wire buffer to borrow")
    func eagerFixedStringColumnReportsNoArena() {
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 4),
            length: 4,
            values: [Data("aaaa".utf8), Data("bbbb".utf8)]
        )
        #expect(!column.hasArena)
        #expect(column.values == [Data("aaaa".utf8), Data("bbbb".utf8)])
    }

}
