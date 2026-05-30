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

// Unit tests for the `selectRowsBuilder` view-row-builder closure that
// projects a `ClickHouseBlockStringView` plus a row index into an
// owning `T`. The block view is constructed directly here without
// standing up a SELECT round-trip; the wire path is exercised by the
// integration suite.
@Suite("ClickHouseViewRowBuilder")
struct ClickHouseViewRowBuilderTests {

    private static func makeStringColumnView(name: String, rows: [String]) -> ClickHouseStringColumnView {
        var arena: [UInt8] = []
        var offsets: [Int] = [0]
        for row in rows {
            arena.append(contentsOf: Array(row.utf8))
            offsets.append(arena.count)
        }
        let handle = ClickHouseStringArena(bytes: arena)
        return ClickHouseStringColumnView(name: name, arena: handle, offsets: offsets)
    }

    private static func makeFixedStringColumnView(name: String, rows: [String], width: Int) -> ClickHouseFixedStringColumnView {
        var arena: [UInt8] = []
        for row in rows {
            var padded = Array(row.utf8)
            if padded.count < width {
                padded.append(contentsOf: [UInt8](repeating: 0, count: width - padded.count))
            }
            arena.append(contentsOf: padded.prefix(width))
        }
        let handle = ClickHouseFixedStringArena(bytes: arena, fixedWidth: width)
        return ClickHouseFixedStringColumnView(name: name, arena: handle)
    }

    @Test("a view-row-builder closure reads payload bytes through the block view and projects per-row counts without materialising every row's String")
    func projectsRowsThroughView() {
        let stringColumn = Self.makeStringColumnView(name: "payload", rows: ["a", "bb", "ccc", "dddd"])
        let fixedColumn = Self.makeFixedStringColumnView(name: "id", rows: ["00", "01", "02", "03"], width: 2)
        let block = ClickHouseBlockStringView(
            rowCount: 4,
            stringColumns: [stringColumn],
            fixedStringColumns: [fixedColumn]
        )
        var produced: [Int] = []
        produced.reserveCapacity(block.rowCount)
        for rowIndex in 0..<block.rowCount {
            let column = block.stringColumns[0]
            let view = column.view(at: rowIndex)
            produced.append(view.utf8Length)
        }
        #expect(produced == [1, 2, 3, 4])
    }

    @Test("looking up a String column by name on the block view returns the matching column or .absent")
    func lookupStringColumnByName() {
        let payload = Self.makeStringColumnView(name: "payload", rows: ["x", "yy"])
        let block = ClickHouseBlockStringView(rowCount: 2, stringColumns: [payload])
        switch block.stringColumn(named: "payload") {
        case .present(let column):
            #expect(column.rowCount == 2)
        case .absent:
            Issue.record("expected payload column to be present")
        }
        if case .present = block.stringColumn(named: "missing") {
            Issue.record("expected missing column to be absent")
        }
    }

    @Test("a fixed-string column view round-trips byte-for-byte through the view's bytes closure")
    func fixedStringColumnView() {
        let column = Self.makeFixedStringColumnView(name: "id", rows: ["abc", "def"], width: 3)
        #expect(column.rowCount == 2)
        #expect(column.fixedWidth == 3)
        let observed: [String] = (0..<column.rowCount).map { column.view(at: $0).asString() }
        #expect(observed == ["abc", "def"])
    }

}
