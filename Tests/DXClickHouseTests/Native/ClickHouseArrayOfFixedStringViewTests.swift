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

@Suite("ClickHouseArrayOfFixedStringView")
struct ClickHouseArrayOfFixedStringViewTests {

    private static func makeColumn(_ rows: [[String]], width: Int) -> ClickHouseArrayOfFixedStringColumnView {
        var arenaBytes: [UInt8] = []
        var offsets: [UInt64] = []
        var elementCount: UInt64 = 0
        for row in rows {
            appendRow(row, width: width, into: &arenaBytes, elementCount: &elementCount)
            offsets.append(elementCount)
        }
        let arena = ClickHouseFixedStringArena(bytes: arenaBytes, fixedWidth: width)
        return ClickHouseArrayOfFixedStringColumnView(name: "refs", elementArena: arena, offsets: offsets)
    }

    private static func appendRow(_ row: [String], width: Int, into arenaBytes: inout [UInt8], elementCount: inout UInt64) {
        for element in row {
            arenaBytes.append(contentsOf: paddedBytes(of: element, width: width))
            elementCount += 1
        }
    }

    private static func paddedBytes(of element: String, width: Int) -> [UInt8] {
        var bytes = Array(element.utf8)
        if bytes.count < width {
            bytes.append(contentsOf: Array(repeating: UInt8(0), count: width - bytes.count))
        }
        return bytes
    }

    @Test("the column view reports one row per offset slot")
    func rowCount() {
        let column = Self.makeColumn([["a"], ["b", "c"], []], width: 1)
        #expect(column.rowCount == 3)
        #expect(column.view(at: 0).count == 1)
        #expect(column.view(at: 1).count == 2)
        #expect(column.view(at: 2).count == 0)
        #expect(column.view(at: 2).isEmpty)
    }

    @Test("element views are addressable inside their row's range")
    func elementAccess() {
        let column = Self.makeColumn([["abcd", "efgh"], ["ijkl"]], width: 4)
        let rowZero = column.view(at: 0)
        #expect(rowZero.count == 2)
        #expect(rowZero.element(at: 0) == "abcd")
        #expect(rowZero.element(at: 1) == "efgh")
        let rowOne = column.view(at: 1)
        #expect(rowOne.element(at: 0) == "ijkl")
    }

    @Test("contains() matches ClickHouse has() semantics on the element views")
    func containsScan() {
        let column = Self.makeColumn(
            [["alpha", "beta-"], ["gamma"], ["beta-"]],
            width: 5
        )
        #expect(column.view(at: 0).contains("alpha"))
        #expect(column.view(at: 0).contains("beta-"))
        #expect(!column.view(at: 0).contains("gamma"))
        #expect(column.view(at: 2).contains("beta-"))
    }

    @Test("forEach walks every element in row order")
    func forEachOrder() {
        let column = Self.makeColumn([["one1", "two2", "thre"]], width: 4)
        var observed: [String] = []
        column.view(at: 0).forEach { _, view in observed.append(view.asString()) }
        #expect(observed == ["one1", "two2", "thre"])
    }

}
