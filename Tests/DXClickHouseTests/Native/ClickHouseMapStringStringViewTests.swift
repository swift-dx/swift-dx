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

@Suite("ClickHouseMapStringStringView")
struct ClickHouseMapStringStringViewTests {

    private static func buildStringColumn(_ strings: [String], name: String) -> ClickHouseStringColumnView {
        var arena: [UInt8] = []
        var offsets: [Int] = [0]
        for string in strings {
            arena.append(contentsOf: Array(string.utf8))
            offsets.append(arena.count)
        }
        let handle = ClickHouseStringArena(bytes: arena)
        return ClickHouseStringColumnView(name: name, arena: handle, offsets: offsets)
    }

    private static func makeColumn(_ rows: [[(String, String)]]) -> ClickHouseMapStringStringColumnView {
        var flatKeys: [String] = []
        var flatValues: [String] = []
        var offsets: [UInt64] = []
        var elementCount: UInt64 = 0
        for row in rows {
            for (key, value) in row {
                flatKeys.append(key)
                flatValues.append(value)
                elementCount += 1
            }
            offsets.append(elementCount)
        }
        return ClickHouseMapStringStringColumnView(
            name: "map",
            keyColumn: buildStringColumn(flatKeys, name: "map::key"),
            valueColumn: buildStringColumn(flatValues, name: "map::value"),
            offsets: offsets
        )
    }

    @Test("rowCount and per-row count match the offsets table")
    func rowAndPairCount() {
        let column = Self.makeColumn([
            [("a", "1"), ("b", "2")],
            [],
            [("c", "3")],
        ])
        #expect(column.rowCount == 3)
        #expect(column.view(at: 0).count == 2)
        #expect(column.view(at: 1).count == 0)
        #expect(column.view(at: 1).isEmpty)
        #expect(column.view(at: 2).count == 1)
    }

    @Test("key/value views borrow from the underlying arenas without allocation")
    func pairAccess() {
        let column = Self.makeColumn([[("env", "prod"), ("region", "nz")]])
        let row = column.view(at: 0)
        #expect(row.key(at: 0) == "env")
        #expect(row.value(at: 0) == "prod")
        #expect(row.key(at: 1) == "region")
        #expect(row.value(at: 1) == "nz")
    }

    @Test("lookup(key:) returns the matching value view and absent for missing keys")
    func keyLookup() {
        let column = Self.makeColumn([[("a", "1"), ("b", "2"), ("c", "3")]])
        let row = column.view(at: 0)
        switch row.lookup(key: "b") {
        case .found(let view): #expect(view == "2")
        case .absent: Issue.record("expected key b to be found")
        }
        switch row.lookup(key: "missing") {
        case .found: Issue.record("expected key 'missing' to be absent")
        case .absent: break
        }
    }

    @Test("forEach walks every pair in row order")
    func forEachOrder() {
        let column = Self.makeColumn([[("first", "1"), ("second", "2"), ("third", "3")]])
        var keys: [String] = []
        var values: [String] = []
        column.view(at: 0).forEach { _, key, value in
            keys.append(key.asString())
            values.append(value.asString())
        }
        #expect(keys == ["first", "second", "third"])
        #expect(values == ["1", "2", "3"])
    }

}
