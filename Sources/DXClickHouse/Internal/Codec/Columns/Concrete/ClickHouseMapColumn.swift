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

import NIOCore

// CH `Map(K, V)` wire layout is identical to `Array(Tuple(K, V))`:
//   - rows × UInt64 cumulative offsets (same monotonicity invariant as
//     ClickHouseArrayColumn)
//   - keys column with offsets.last total elements
//   - values column with offsets.last total elements
//
// We keep Map distinct from Array(Tuple(...)) at the spec/column layer
// because callers care about the semantic distinction even though the
// bytes coincide.
struct ClickHouseMapColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let keySpec: ClickHouseColumnSpec
    let valueSpec: ClickHouseColumnSpec
    var offsets: [UInt64]
    var keys: any ClickHouseColumn
    var values: any ClickHouseColumn

    var rowCount: Int { offsets.count }

    func encodePrefix(into buffer: inout ByteBuffer) throws {
        try keys.encodePrefix(into: &buffer)
        try values.encodePrefix(into: &buffer)
    }

    func encode(into buffer: inout ByteBuffer) throws {
        try Self.validateMonotonic(offsets: offsets)
        let totalElements = try Self.requireTotalElements(offsets: offsets)
        try Self.requireInnerRowCount(column: keys, expected: totalElements)
        try Self.requireInnerRowCount(column: values, expected: totalElements)
        buffer.writeClickHouseFixedWidthIntegers(offsets)
        try keys.encode(into: &buffer)
        try values.encode(into: &buffer)
    }

    static func decode(keySpec: ClickHouseColumnSpec, valueSpec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let offsets = try buffer.readClickHouseFixedWidthIntegers(UInt64.self, rows: rows)
        try validateMonotonic(offsets: offsets)
        let totalElements = try requireTotalElements(offsets: offsets)
        let keys = try ClickHouseColumnRegistry.decode(spec: keySpec, rows: totalElements, from: &buffer)
        try requireInnerRowCount(column: keys, expected: totalElements)
        let values = try ClickHouseColumnRegistry.decode(spec: valueSpec, rows: totalElements, from: &buffer)
        try requireInnerRowCount(column: values, expected: totalElements)
        return .init(
            spec: .map(key: keySpec, value: valueSpec),
            keySpec: keySpec,
            valueSpec: valueSpec,
            offsets: offsets,
            keys: keys,
            values: values
        )
    }

    private static func requireTotalElements(offsets: [UInt64]) throws -> Int {
        let lastOffset = offsets.last ?? 0
        guard let totalElements = Int(exactly: lastOffset) else {
            throw ClickHouseError.arrayOffsetExceedsInt(lastOffset)
        }
        return totalElements
    }

    private static func requireInnerRowCount(column: any ClickHouseColumn, expected: Int) throws {
        guard column.rowCount == expected else {
            throw ClickHouseError.nullableInnerRowCountMismatch(
                expected: expected,
                actual: column.rowCount
            )
        }
    }

    private static func validateMonotonic(offsets: [UInt64]) throws {
        var previous: UInt64 = 0
        for (index, offset) in offsets.enumerated() {
            guard offset >= previous else {
                throw ClickHouseError.nonMonotonicArrayOffsets(at: index, value: offset, previous: previous)
            }
            previous = offset
        }
    }

}
