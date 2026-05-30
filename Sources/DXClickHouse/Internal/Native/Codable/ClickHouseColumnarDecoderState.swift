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

// Per-block shared state for the columnar fast-path decoder. One
// instance is constructed per `ClickHouseSelectBlock`; every row in
// the block reuses the same instance with only `rowIndex` mutated
// between rows. This shape is the structural answer to the per-row
// hot path: column-by-name lookup, KeyDecodingStrategy application,
// `Values`-enum unwrap, and column-count validation all happen
// exactly once per block instead of once per row per field.
//
// The slot cache (`slotByKey`) memoises CodingKey → column-index
// resolution as new keys are encountered, so the first row in a
// block fills the cache and subsequent rows in the same block hit
// it on every field. Across blocks the cache resets because column
// order on the wire is the same per query but the typed-column
// references are fresh per block.
//
// `columnsValues` is the pre-unwrapped column array indexed by
// column position. The keyed container indexes it by `Int` after
// resolving the CodingKey through the slot cache, replacing every
// per-row `Dictionary<String, Values>.find` call with two array
// subscripts.
//
// `SlotLookup` carries either the resolved index or an explicit
// "not in result" marker. The marker is stored in the slot cache
// the same way as a hit so the next row in the block doesn't redo
// the strategy translation either.
enum ClickHouseColumnSlotLookup: Sendable, Equatable {

    case present(Int)
    case absent

}

// Classifier for the generic `decode<T: Decodable>(_:forKey:)` path.
// Maps a Decodable type metatype to its dispatch case so the keyed
// container can route via an exhaustive switch instead of a chain of
// `if let` checks that would otherwise hit the cyclomatic-complexity
// cap.
//
// Includes `Date` and `UUID` because Foundation's `KeyedDecodingContainer`
// protocol does not declare typed overloads for them: a `Date`/`UUID`
// field in a Codable struct routes through the generic `decode<T>`
// path and `T == Date` / `T == UUID` discrimination must happen here.
import Foundation

enum ClickHouseColumnarDispatchTarget: Sendable, Equatable {

    case date
    case uuid
    case stringStringMap
    case uint64Array
    case doubleArray
    case unsupported

}

enum ClickHouseColumnarDispatch {

    static func classify<T: Decodable>(_ type: T.Type) -> ClickHouseColumnarDispatchTarget {
        if type == Date.self { return .date }
        if type == UUID.self { return .uuid }
        return classifyContainer(type)
    }

    private static func classifyContainer<T: Decodable>(_ type: T.Type) -> ClickHouseColumnarDispatchTarget {
        if type == [String: String].self { return .stringStringMap }
        return classifyArray(type)
    }

    private static func classifyArray<T: Decodable>(_ type: T.Type) -> ClickHouseColumnarDispatchTarget {
        if type == [UInt64].self { return .uint64Array }
        if type == [Double].self { return .doubleArray }
        return .unsupported
    }

}

final class ClickHouseColumnarDecoderState {

    let columns: [ClickHouseSelectColumn]
    let columnsValues: [ClickHouseColumnEntry.Values]
    let columnIndexByName: [String: Int]
    let keyDecodingStrategy: ClickHouseKeyDecodingStrategy
    let rowCount: Int
    var rowIndex: Int = 0
    // Parallel-array slot cache. Indexed lookups beat Dictionary for
    // typical Decodable struct widths (1-10 columns): a linear scan
    // over a tiny String array avoids the per-field Hasher seed setup,
    // SipHash13 of the key bytes, and Dictionary probe sequence that
    // collectively cost ~5.5% of cycles in the fast SELECT path. The
    // cache fills lazily on first reference to each CodingKey and is
    // reused across every row in the block.
    var slotKeys: ContiguousArray<String>
    var slotLookups: ContiguousArray<ClickHouseColumnSlotLookup>

    init(columns: [ClickHouseSelectColumn], keyDecodingStrategy: ClickHouseKeyDecodingStrategy) throws(ClickHouseError) {
        self.columns = columns
        self.keyDecodingStrategy = keyDecodingStrategy
        var values: [ClickHouseColumnEntry.Values] = []
        values.reserveCapacity(columns.count)
        var byName: [String: Int] = .init(minimumCapacity: columns.count)
        var observedRowCount = ClickHouseColumnarDecoderState.RowCountWitness.unset
        for (position, column) in columns.enumerated() {
            try Self.requireConsistentRowCount(column: column, witness: &observedRowCount)
            values.append(column.values)
            byName[column.name] = position
        }
        self.columnsValues = values
        self.columnIndexByName = byName
        var keys = ContiguousArray<String>()
        keys.reserveCapacity(columns.count)
        var lookups = ContiguousArray<ClickHouseColumnSlotLookup>()
        lookups.reserveCapacity(columns.count)
        self.slotKeys = keys
        self.slotLookups = lookups
        switch observedRowCount {
        case .observed(let value): self.rowCount = value
        case .unset: self.rowCount = 0
        }
    }

    private enum RowCountWitness {

        case unset
        case observed(Int)

    }

    private static func requireConsistentRowCount(column: ClickHouseSelectColumn, witness: inout RowCountWitness) throws(ClickHouseError) {
        let count = column.values.rowCount
        switch witness {
        case .unset:
            witness = .observed(count)
        case .observed(let expected):
            if count != expected {
                throw ClickHouseError.rowDecoderMismatchedColumnRowCounts(
                    columnName: column.name, expected: expected, actual: count
                )
            }
        }
    }

    // Resolves a CodingKey to the column-position slot, caching the
    // result so subsequent rows in the same block skip the hash and
    // strategy-translation work entirely. The .absent case is also
    // cached so a Decodable type asking for a column that is not in
    // the SELECT result only pays the lookup cost once.
    //
    // The cache is a small parallel array scanned linearly because
    // typical Decodable struct widths (1-10 columns) make a hash table
    // a net loss: SipHash13 of the key bytes plus a probe sequence
    // costs more than a tight loop of String byte comparisons over
    // the same number of entries.
    //
    // The read path uses `withUnsafeBufferPointer` on both arrays so
    // the per-field hot-path scan avoids the exclusivity-check that
    // Swift's `_read` accessor emits on every subscript of a `var`
    // property. Inside the unsafe block the compiler proves there is
    // no mutation in flight and the scan compiles to a tight cmp/jne
    // loop over String guts.
    @inline(__always)
    func slot(for keyString: String) -> ClickHouseColumnSlotLookup {
        let count = slotKeys.count
        for index in 0..<count {
            if slotKeys[index] == keyString {
                return slotLookups[index]
            }
        }
        return slotMiss(keyString: keyString)
    }

    @inline(never)
    private func slotMiss(keyString: String) -> ClickHouseColumnSlotLookup {
        let lookupName = keyDecodingStrategy.columnName(forSwiftKey: keyString)
        let resolved: ClickHouseColumnSlotLookup
        if let position = columnIndexByName[lookupName] {
            resolved = .present(position)
        } else {
            resolved = .absent
        }
        slotKeys.append(keyString)
        slotLookups.append(resolved)
        return resolved
    }

}
