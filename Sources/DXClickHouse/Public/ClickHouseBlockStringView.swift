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

// One SELECT block exposed exclusively through zero-copy column-view
// projections. Built by `selectStringColumns` and consumed by
// `selectRowsBuilder`, which decode the block normally and then hand
// back this projection in place of the standard
// `ClickHouseSelectBlock`.
//
// The block keeps a strong reference to every column's arena, so
// every view obtained through any of the typed lookup methods stays
// alive for as long as this value or any view derived from it does.
// Columns that are not view-supported (e.g. unsupported Map shapes,
// numeric columns) are not exposed by this projection — callers that
// need them should reach for the standard `selectColumns` API.
//
// Lifetime contract for callers iterating the block:
//
//   - Inside a `selectStringColumns` stream loop the block lives until
//     the next iteration; every view obtained from it (including
//     views vended by `view(at:)` on any column) is valid until the
//     loop body returns.
//
//   - Inside a `selectRowsBuilder` row-builder closure the views are
//     valid only for the duration of the closure call. Returning a
//     view (or a type that captures one) from the closure escapes the
//     block bytes through the per-row `T` and defeats the entire
//     allocation-avoidance goal of this path. The block's arena
//     references will keep the bytes alive — the rule is a behavioural
//     contract, not a memory-safety one. If the row needs an owning
//     payload past the closure, materialise it with
//     `view.asString()`.
//
// Surfaces today:
//   - String columns                              (Phase 3)
//   - FixedString(N) columns                      (Phase 4)
//   - Array(FixedString(N)) columns               (Phase 4)
//   - Map(String, String) columns                 (Phase 4)
//   - Map(LowCardinality(String), String) columns (Phase 4)
public struct ClickHouseBlockStringView: Sendable {

    public let rowCount: Int
    public let stringColumns: [ClickHouseStringColumnView]
    public let fixedStringColumns: [ClickHouseFixedStringColumnView]
    public let arrayOfFixedStringColumns: [ClickHouseArrayOfFixedStringColumnView]
    public let mapStringStringColumns: [ClickHouseMapStringStringColumnView]

    public init(
        rowCount: Int,
        stringColumns: [ClickHouseStringColumnView],
        fixedStringColumns: [ClickHouseFixedStringColumnView] = [],
        arrayOfFixedStringColumns: [ClickHouseArrayOfFixedStringColumnView] = [],
        mapStringStringColumns: [ClickHouseMapStringStringColumnView] = []
    ) {
        self.rowCount = rowCount
        self.stringColumns = stringColumns
        self.fixedStringColumns = fixedStringColumns
        self.arrayOfFixedStringColumns = arrayOfFixedStringColumns
        self.mapStringStringColumns = mapStringStringColumns
    }

    // Look up a String column by name. Returns the typed lookup
    // outcome; the caller switches over the cases to distinguish
    // "present" from "absent". Mirrors `ClickHouseSelectBlock`'s
    // column-lookup ergonomics.
    public func stringColumn(named: String) -> Lookup {
        if let match = stringColumns.first(where: { $0.name == named }) {
            return .present(match)
        }
        return .absent
    }

    // Throwing variant for callers that treat absence as a hard
    // failure.
    public func requireStringColumn(named: String) throws(ClickHouseError) -> ClickHouseStringColumnView {
        switch stringColumn(named: named) {
        case .present(let column): return column
        case .absent:
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "missing string column \(named)")
        }
    }

    public func fixedStringColumn(named: String) -> FixedStringLookup {
        if let match = fixedStringColumns.first(where: { $0.name == named }) {
            return .present(match)
        }
        return .absent
    }

    public func requireFixedStringColumn(named: String) throws(ClickHouseError) -> ClickHouseFixedStringColumnView {
        switch fixedStringColumn(named: named) {
        case .present(let column): return column
        case .absent:
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "missing fixed-string column \(named)")
        }
    }

    public func arrayOfFixedStringColumn(named: String) -> ArrayOfFixedStringLookup {
        if let match = arrayOfFixedStringColumns.first(where: { $0.name == named }) {
            return .present(match)
        }
        return .absent
    }

    public func requireArrayOfFixedStringColumn(named: String) throws(ClickHouseError) -> ClickHouseArrayOfFixedStringColumnView {
        switch arrayOfFixedStringColumn(named: named) {
        case .present(let column): return column
        case .absent:
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "missing array(fixed-string) column \(named)")
        }
    }

    public func mapStringStringColumn(named: String) -> MapStringStringLookup {
        if let match = mapStringStringColumns.first(where: { $0.name == named }) {
            return .present(match)
        }
        return .absent
    }

    public func requireMapStringStringColumn(named: String) throws(ClickHouseError) -> ClickHouseMapStringStringColumnView {
        switch mapStringStringColumn(named: named) {
        case .present(let column): return column
        case .absent:
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "missing map(string,string) column \(named)")
        }
    }

    public enum Lookup: Sendable {

        case present(ClickHouseStringColumnView)
        case absent

    }

    public enum FixedStringLookup: Sendable {

        case present(ClickHouseFixedStringColumnView)
        case absent

    }

    public enum ArrayOfFixedStringLookup: Sendable {

        case present(ClickHouseArrayOfFixedStringColumnView)
        case absent

    }

    public enum MapStringStringLookup: Sendable {

        case present(ClickHouseMapStringStringColumnView)
        case absent

    }

}
