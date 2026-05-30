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

// Lazy storage for a `Map(String, String)` or
// `Map(LowCardinality(String), String)` column on the SELECT side.
// Holds the flat key/value arrays and cumulative offsets exactly as
// they arrive on the wire; per-row `[String: String]` dictionaries
// are constructed only when the consumer reads a row, not at block
// decode time.
//
// Compared with the previous representation
// (`[[String: String]]` materialised once per block), this
// removes:
//
//   - `rowCount` `Dictionary<String, String>` allocations and the
//     associated hashing work that ran during block decoding.
//   - For `Map(LowCardinality(String), String)`, the flat
//     `[String]` of length `offsets.last` that the previous
//     resolver allocated to hold every key by value.
//
// The `keys` case `.lowCardinality` preserves the
// (dictionary, indices) view of the key column so `row(at:)` resolves
// each key with a single dictionary subscript inside the inner loop.
//
// Decoders that ultimately need a `[String: String]` per row call
// `row(at:)`, which performs a single sized allocation per row,
// pulls keys and values from the flat slice, and never touches
// blocks the row does not consume.
public struct ClickHouseMapStringStringStorage: Sendable {

    public enum Keys: Sendable {

        case direct([String])
        case lowCardinality(dictionary: [String], indices: [UInt64])

    }

    public let keys: Keys
    public let values: [String]
    public let offsets: [UInt64]

    public init(keys: Keys, values: [String], offsets: [UInt64]) {
        self.keys = keys
        self.values = values
        self.offsets = offsets
    }

    public var count: Int { offsets.count }

    public func row(at rowIndex: Int) -> [String: String] {
        let start = rowIndex == 0 ? 0 : Int(offsets[rowIndex - 1])
        let end = Int(offsets[rowIndex])
        switch keys {
        case .direct(let keyArray):
            return Self.buildDirect(keys: keyArray, values: values, range: start..<end)
        case .lowCardinality(let dictionary, let indices):
            return Self.buildLowCardinality(
                dictionary: dictionary, indices: indices, values: values, range: start..<end
            )
        }
    }

    @inline(__always)
    private static func buildDirect(keys: [String], values: [String], range: Range<Int>) -> [String: String] {
        let entryCount = range.count
        if entryCount == 0 { return [:] }
        var dict = [String: String](minimumCapacity: entryCount)
        for index in range { dict[keys[index]] = values[index] }
        return dict
    }

    @inline(__always)
    private static func buildLowCardinality(
        dictionary: [String], indices: [UInt64], values: [String], range: Range<Int>
    ) -> [String: String] {
        let entryCount = range.count
        if entryCount == 0 { return [:] }
        var dict = [String: String](minimumCapacity: entryCount)
        for index in range {
            dict[dictionary[Int(indices[index])]] = values[index]
        }
        return dict
    }

}
