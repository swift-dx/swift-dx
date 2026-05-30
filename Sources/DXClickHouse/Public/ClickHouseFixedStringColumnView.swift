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

// One `FixedString(N)` column from a SELECT block, exposed as a
// sequence of `ClickHouseFixedStringView` rows that all borrow from
// the same per-block byte arena. Holds a strong reference to the
// arena so every view obtained through `view(at:)` stays alive
// independently of this column instance.
//
// Use `view(at:)` for random access, `forEach` for a fast linear walk
// that avoids the per-row Swift `String` allocation, or
// `materialiseStrings()` when the caller needs an owning `[String]`.
public struct ClickHouseFixedStringColumnView: Sendable {

    public let name: String

    @usableFromInline
    let arena: ClickHouseFixedStringArena

    @inlinable
    init(name: String, arena: ClickHouseFixedStringArena) {
        self.name = name
        self.arena = arena
    }

    @inlinable
    public var rowCount: Int { arena.rowCount }

    @inlinable
    public var fixedWidth: Int { arena.fixedWidth }

    @inlinable
    public func view(at rowIndex: Int) -> ClickHouseFixedStringView {
        ClickHouseFixedStringView(arena: arena, rowIndex: rowIndex)
    }

    // Linear walk over every row, invoking `body` with the row index
    // and a view borrowed from the arena. The view is valid only
    // inside the call to `body`; treat it the same as a closure
    // parameter.
    @inlinable
    public func forEach(_ body: (Int, ClickHouseFixedStringView) -> Void) {
        for index in 0..<rowCount {
            body(index, view(at: index))
        }
    }

    // Materialise every row into an owning Swift `String`. Allocates
    // `rowCount` heap strings and copies the bytes from the arena
    // into each one. Equivalent to walking `view(at:)` and calling
    // `asString()` on each row.
    public func materialiseStrings() -> [String] {
        var result: [String] = []
        result.reserveCapacity(rowCount)
        forEach { _, view in
            result.append(view.asString())
        }
        return result
    }

}
