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

// One `Array(FixedString(N))` column from a SELECT block, exposed as
// a sequence of `ClickHouseArrayOfFixedStringView` rows. Each row
// view borrows from the inner FixedString column's arena plus the
// Array's cumulative offsets; no `[[String]]` is built unless the
// caller asks for one.
//
// Holds strong references to the element arena and offsets so every
// view obtained through `view(at:)` stays alive independently of this
// column instance.
public struct ClickHouseArrayOfFixedStringColumnView: Sendable {

    public let name: String

    @usableFromInline
    let elementArena: ClickHouseFixedStringArena
    @usableFromInline
    let offsets: [UInt64]

    @inlinable
    init(name: String, elementArena: ClickHouseFixedStringArena, offsets: [UInt64]) {
        self.name = name
        self.elementArena = elementArena
        self.offsets = offsets
    }

    @inlinable
    public var rowCount: Int { offsets.count }

    @inlinable
    public var fixedWidth: Int { elementArena.fixedWidth }

    @inlinable
    public func view(at rowIndex: Int) -> ClickHouseArrayOfFixedStringView {
        let previousEnd = rowIndex == 0 ? 0 : Int(offsets[rowIndex - 1])
        let currentEnd = Int(offsets[rowIndex])
        return ClickHouseArrayOfFixedStringView(
            elementArena: elementArena,
            startIndex: previousEnd,
            endIndex: currentEnd
        )
    }

    @inlinable
    public func forEach(_ body: (Int, ClickHouseArrayOfFixedStringView) -> Void) {
        for index in 0..<rowCount {
            body(index, view(at: index))
        }
    }

}
