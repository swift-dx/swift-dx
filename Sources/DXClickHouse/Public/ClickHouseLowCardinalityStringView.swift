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

// Compact representation of a `LowCardinality(String)` column on the
// SELECT side. The dictionary holds every distinct string value at
// most once; `indices` is the per-row pointer into the dictionary.
// Together they describe `indices.count` rows without ever
// materialising a flat `[String]` of length `indices.count`.
//
// Decoders read a single row as `dictionary[Int(indices[row])]` —
// one dictionary lookup, no allocation. Compared with the
// flat-`[String]` representation, the storage cost drops from
// `indices.count * String` (one boxed String per row, each retaining
// the underlying buffer) to `dictionary.count * String +
// indices.count * UInt64`. For a 100k-row block with three distinct
// environment names this is a ~24x memory reduction and removes
// 100k String retains from the per-block hot path.
//
// Bounds: `indices[row]` is the dictionary index assigned by the
// ClickHouse server; well-formed wire data keeps it within
// `0..<dictionary.count`. The wire decoder validates the bound at
// block decode time and throws
// `ClickHouseError.lowCardinalityDictionaryIndexOutOfRange` if a
// malformed block ever ships a stray index.
public struct ClickHouseLowCardinalityStringView: Sendable {

    public let dictionary: [String]
    public let indices: [UInt64]

    public init(dictionary: [String], indices: [UInt64]) {
        self.dictionary = dictionary
        self.indices = indices
    }

    public var count: Int { indices.count }

    public subscript(rowIndex: Int) -> String {
        dictionary[Int(indices[rowIndex])]
    }

}
