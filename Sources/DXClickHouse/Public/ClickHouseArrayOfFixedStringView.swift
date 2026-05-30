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

// One `Array(FixedString(N))` row, exposed as a borrowed sequence of
// `ClickHouseFixedStringView` element views. The element views borrow
// from the inner FixedString column's arena; iterating the row
// performs zero heap allocation per element.
//
// Wire layout: `Array(T)` is a `[UInt64]` cumulative offsets table
// followed by the inner column carrying `offsets.last` rows in total.
// This view captures the per-row half-open range
// `[startIndex, endIndex)` into the inner arena.
//
// Highest-leverage view in event-sourced ledger workloads: `has(refs, ?)` is
// the most-queried filter, and the `entity_refs` column is
// `Array(FixedString(44))`. The standard `selectColumns` path
// materialises `[[String]]` for the whole block; this view leaves the
// payload bytes in the arena and only materialises a `String` for the
// rows that the caller's filter selects.
public struct ClickHouseArrayOfFixedStringView: Sendable {

    @usableFromInline
    let elementArena: ClickHouseFixedStringArena
    @usableFromInline
    let startIndex: Int
    @usableFromInline
    let endIndex: Int

    @inlinable
    init(elementArena: ClickHouseFixedStringArena, startIndex: Int, endIndex: Int) {
        self.elementArena = elementArena
        self.startIndex = startIndex
        self.endIndex = endIndex
    }

    @inlinable
    public var count: Int { endIndex - startIndex }

    @inlinable
    public var isEmpty: Bool { count == 0 }

    @inlinable
    public var fixedWidth: Int { elementArena.fixedWidth }

    @inlinable
    public func element(at offset: Int) -> ClickHouseFixedStringView {
        ClickHouseFixedStringView(arena: elementArena, rowIndex: startIndex + offset)
    }

    // Linear walk over every element, invoking `body` with the
    // element index (0-based within this row) and the borrowed view.
    // The view is valid only inside the call to `body`.
    @inlinable
    public func forEach(_ body: (Int, ClickHouseFixedStringView) -> Void) {
        for offset in 0..<count {
            body(offset, element(at: offset))
        }
    }

    // True when any element in the row byte-equals `needle`. Mirrors
    // ClickHouse's `has(array, value)`. Iterates element views in
    // place and skips Swift String materialisation entirely.
    public func contains(_ needle: ClickHouseFixedStringView) -> Bool {
        for offset in 0..<count {
            if element(at: offset) == needle { return true }
        }
        return false
    }

    public func contains(_ needle: String) -> Bool {
        for offset in 0..<count {
            if element(at: offset) == needle { return true }
        }
        return false
    }

}
