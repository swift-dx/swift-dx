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

// One `Map(String, String)` column from a SELECT block, exposed as a
// sequence of `ClickHouseMapStringStringView` rows. Each row view
// borrows from the column's underlying key and value `String` arenas
// plus the Map's cumulative offsets; no `[String: String]` dictionary
// is built unless the caller explicitly asks for one.
//
// Holds strong references to the underlying key column, value column,
// and offsets array, so every view obtained through `view(at:)` stays
// alive independently of this column instance.
public struct ClickHouseMapStringStringColumnView: Sendable {

    public let name: String

    @usableFromInline
    let keyColumn: ClickHouseStringColumnView
    @usableFromInline
    let valueColumn: ClickHouseStringColumnView
    @usableFromInline
    let offsets: [UInt64]

    @inlinable
    init(name: String, keyColumn: ClickHouseStringColumnView, valueColumn: ClickHouseStringColumnView, offsets: [UInt64]) {
        self.name = name
        self.keyColumn = keyColumn
        self.valueColumn = valueColumn
        self.offsets = offsets
    }

    @inlinable
    public var rowCount: Int { offsets.count }

    @inlinable
    public func view(at rowIndex: Int) -> ClickHouseMapStringStringView {
        let previousEnd = rowIndex == 0 ? 0 : Int(offsets[rowIndex - 1])
        let currentEnd = Int(offsets[rowIndex])
        return ClickHouseMapStringStringView(
            keyColumn: keyColumn,
            valueColumn: valueColumn,
            startIndex: previousEnd,
            endIndex: currentEnd
        )
    }

    // Linear walk over every row, invoking `body` with the row index
    // and a view borrowed from the arenas. The view is valid only
    // inside the call to `body`; treat it the same as a closure
    // parameter.
    @inlinable
    public func forEach(_ body: (Int, ClickHouseMapStringStringView) -> Void) {
        for index in 0..<rowCount {
            body(index, view(at: index))
        }
    }

}
