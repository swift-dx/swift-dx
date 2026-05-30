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

// One `Map(String, String)` row, exposed as a borrowed sequence of
// `(key, value)` `ClickHouseStringView` pairs. The pairs borrow from
// the underlying key and value arenas held by the column; constructing
// or iterating a view performs zero heap allocation per pair.
//
// Wire layout: a `Map(K, V)` column is identical to
// `Array(Tuple(K, V))` on the wire — a `[UInt64]` cumulative offsets
// table plus separate `K` and `V` substream columns of total length
// `offsets.last`. This view captures the per-row half-open range
// `[startIndex, endIndex)` into the substream arenas; element `i` in
// the row is the pair `(keyView(startIndex + i), valueView(startIndex + i))`.
//
// `subscript(key:)` does a linear scan over the row's pairs and
// returns the first matching value view. The cost is `O(rowLength)`
// per lookup; for the small per-row map sizes typical of audit-event
// schemas (3-30 keys) this is competitive with `Dictionary` lookup
// and avoids the per-row `[String: String]` allocation entirely.
public struct ClickHouseMapStringStringView: Sendable {

    @usableFromInline
    let keyColumn: ClickHouseStringColumnView
    @usableFromInline
    let valueColumn: ClickHouseStringColumnView
    @usableFromInline
    let startIndex: Int
    @usableFromInline
    let endIndex: Int

    @inlinable
    init(keyColumn: ClickHouseStringColumnView, valueColumn: ClickHouseStringColumnView, startIndex: Int, endIndex: Int) {
        self.keyColumn = keyColumn
        self.valueColumn = valueColumn
        self.startIndex = startIndex
        self.endIndex = endIndex
    }

    @inlinable
    public var count: Int { endIndex - startIndex }

    @inlinable
    public var isEmpty: Bool { count == 0 }

    @inlinable
    public func key(at offset: Int) -> ClickHouseStringView {
        keyColumn.view(at: startIndex + offset)
    }

    @inlinable
    public func value(at offset: Int) -> ClickHouseStringView {
        valueColumn.view(at: startIndex + offset)
    }

    // Linear lookup by key. Returns `.found` with the matching value
    // view, or `.absent` when no pair has a matching key. Uses
    // `ClickHouseStringView`'s byte-equality so the lookup never
    // materialises the key into a Swift `String`.
    public func lookup(key: String) -> Lookup {
        for offset in 0..<count {
            if self.key(at: offset) == key {
                return .found(value(at: offset))
            }
        }
        return .absent
    }

    public enum Lookup: Sendable {

        case found(ClickHouseStringView)
        case absent

    }

    // Linear walk over every pair, invoking `body` with the index
    // (0-based within this row), key view, and value view. The views
    // are valid only inside the call to `body`; treat them the same
    // as closure parameters.
    @inlinable
    public func forEach(_ body: (Int, ClickHouseStringView, ClickHouseStringView) -> Void) {
        for offset in 0..<count {
            body(offset, key(at: offset), value(at: offset))
        }
    }

}
