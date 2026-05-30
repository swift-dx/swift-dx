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

// One String column from a SELECT block, exposed as a sequence of
// `ClickHouseStringView` rows that all borrow from the same
// per-block UTF-8 arena. Holds a strong reference to the arena and
// the offsets index that names every row's byte range.
//
// Use `view(at:)` for random access, `forEach` for a fast linear
// walk that avoids the per-row Swift `String` allocation, or
// `materialiseStrings()` when the caller needs an owning
// `[String]` (one heap String per row).
public struct ClickHouseStringColumnView: Sendable {

    public let name: String

    @usableFromInline
    let arena: ClickHouseStringArena
    @usableFromInline
    let offsets: [Int]

    @inlinable
    init(name: String, arena: ClickHouseStringArena, offsets: [Int]) {
        self.name = name
        self.arena = arena
        self.offsets = offsets
    }

    @inlinable
    public var rowCount: Int { max(0, offsets.count - 1) }

    @inlinable
    public func view(at rowIndex: Int) -> ClickHouseStringView {
        let start = offsets[rowIndex]
        let end = offsets[rowIndex + 1]
        return ClickHouseStringView(arena: arena, byteOffset: start, byteCount: end - start)
    }

    // Linear walk over every row, invoking `body` with the row
    // index and a view borrowed from the arena. The view is valid
    // only inside the call to `body`; treat it the same as a
    // closure parameter.
    @inlinable
    public func forEach(_ body: (Int, ClickHouseStringView) -> Void) {
        for index in 0..<rowCount {
            body(index, view(at: index))
        }
    }

    // Materialise every row into an owning Swift `String`. Allocates
    // `rowCount` heap strings and copies the UTF-8 payload from the
    // arena into each one. Equivalent to walking `view(at:)` and
    // calling `asString()` on each row.
    public func materialiseStrings() -> [String] {
        var result: [String] = []
        result.reserveCapacity(rowCount)
        forEach { _, view in
            result.append(view.asString())
        }
        return result
    }

}
