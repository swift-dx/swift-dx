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

// CH `Array(T)` wire layout:
//   - rows × UInt64 cumulative offsets (offsets[i] = exclusive end of row
//     i in the flattened inner column; offsets[i] >= offsets[i-1] always)
//   - the inner column carrying offsets.last total elements
//
// The inner column is decoded recursively through the registry, which is
// the seam that lets nested composites (e.g. `Array(Nullable(String))`)
// unwind without bespoke dispatch at every level.
struct ClickHouseArrayColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let elementSpec: ClickHouseColumnSpec
    var offsets: [UInt64]
    var inner: any ClickHouseColumn

    var rowCount: Int { offsets.count }

    func encodePrefix(into buffer: inout ByteBuffer) throws {
        try inner.encodePrefix(into: &buffer)
    }

    func encode(into buffer: inout ByteBuffer) throws {
        // Symmetric with the decoder: check monotonicity, decode-able
        // last offset, and inner row-count match. Without these the
        // encoder would silently produce wire bytes the server rejects,
        // costing a full network round-trip to surface what we already
        // knew client-side.
        try Self.validateMonotonic(offsets: offsets)
        let lastOffset = offsets.last ?? 0
        guard let totalElements = Int(exactly: lastOffset) else {
            throw ClickHouseError.arrayOffsetExceedsInt(lastOffset)
        }
        guard inner.rowCount == totalElements else {
            throw ClickHouseError.nullableInnerRowCountMismatch(
                expected: totalElements,
                actual: inner.rowCount
            )
        }
        buffer.writeClickHouseFixedWidthIntegers(offsets)
        try inner.encode(into: &buffer)
    }

    static func decode(elementSpec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let offsets = try buffer.readClickHouseFixedWidthIntegers(UInt64.self, rows: rows)
        try validateMonotonic(offsets: offsets)
        let lastOffset = offsets.last ?? 0
        guard let totalElements = Int(exactly: lastOffset) else {
            throw ClickHouseError.arrayOffsetExceedsInt(lastOffset)
        }
        let inner = try ClickHouseColumnRegistry.decode(spec: elementSpec, rows: totalElements, from: &buffer)
        // Defense-in-depth: a buggy inner codec that doesn't honor the
        // `rows` contract would leave callers iterating
        // `inner[offsets[i-1]..<offsets[i]]` past the inner array's
        // backing storage. Reject the divergence at the boundary.
        guard inner.rowCount == totalElements else {
            throw ClickHouseError.nullableInnerRowCountMismatch(
                expected: totalElements,
                actual: inner.rowCount
            )
        }
        return .init(
            spec: .array(of: elementSpec),
            elementSpec: elementSpec,
            offsets: offsets,
            inner: inner
        )
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
