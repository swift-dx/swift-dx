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

// A parsed result block presented as direct views into the received bytes, for
// the fused decode path (ClickHouseFusedDecodable). Fixed-width columns are
// read in place from the body with no intermediate array; variable-width
// String columns are scanned once into byte ranges (no per-row allocation),
// the same shape ClickHouse's own clients use. A conforming type reads each
// field per row straight from these views, so decoding is a single pass over
// the bytes — no copy into typed columns first.
//
// The views borrow the connection's receive buffer and are valid only for the
// duration of the decode call; the decoded values are copied out into the
// returned rows.
public struct ClickHouseRawBlock {

    @usableFromInline let base: UnsafeRawPointer
    @usableFromInline let columnBaseOffset: [Int]
    // String element bounds stored as a single flat [Int] of interleaved
    // (start, length) pairs across every String column, rather than a nested
    // [[Range<Int>]]. A nested array charges an ARC retain/release on the inner
    // column buffer for every per-row access (stringRanges[field][row]); the
    // flat [Int] is a trivial element type, so per-row string access is two
    // bounds-checked loads with no reference-counting traffic.
    @usableFromInline let stringSpans: [Int]
    // Per field, the base index into stringSpans where that field's row 0 lives
    // (field row r is at stringSpans[stringFieldBase[field] + 2*r ..< +2]).
    // -1 marks a non-String column, which never reaches the string accessor.
    @usableFromInline let stringFieldBase: [Int]
    public let count: Int

    // The accessors are @inlinable so a conforming type's decodeFused — which
    // lives in the consumer's module — inlines them into its per-row loop
    // instead of emitting one cross-module call per field per row. Inlining
    // lets the optimizer hoist `base` and the per-field column offset out of
    // the loop, the difference between a call-per-field decode and a flat
    // pointer walk. The stored properties are @usableFromInline so the inlined
    // bodies can reference them across the module boundary.
    @usableFromInline init(base: UnsafeRawPointer, columnBaseOffset: [Int], stringSpans: [Int], stringFieldBase: [Int], count: Int) {
        self.base = base
        self.columnBaseOffset = columnBaseOffset
        self.stringSpans = stringSpans
        self.stringFieldBase = stringFieldBase
        self.count = count
    }

    @inlinable public func uint64(_ field: Int, _ row: Int) -> UInt64 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 8, as: UInt64.self)
    }

    @inlinable public func int64(_ field: Int, _ row: Int) -> Int64 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 8, as: Int64.self)
    }

    @inlinable public func uint32(_ field: Int, _ row: Int) -> UInt32 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 4, as: UInt32.self)
    }

    @inlinable public func int32(_ field: Int, _ row: Int) -> Int32 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 4, as: Int32.self)
    }

    @inlinable public func uint16(_ field: Int, _ row: Int) -> UInt16 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 2, as: UInt16.self)
    }

    @inlinable public func int16(_ field: Int, _ row: Int) -> Int16 {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 2, as: Int16.self)
    }

    @inlinable public func uint8(_ field: Int, _ row: Int) -> UInt8 {
        base.load(fromByteOffset: columnBaseOffset[field] + row, as: UInt8.self)
    }

    @inlinable public func int8(_ field: Int, _ row: Int) -> Int8 {
        base.load(fromByteOffset: columnBaseOffset[field] + row, as: Int8.self)
    }

    @inlinable public func double(_ field: Int, _ row: Int) -> Double {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 8, as: Double.self)
    }

    @inlinable public func float(_ field: Int, _ row: Int) -> Float {
        base.loadUnaligned(fromByteOffset: columnBaseOffset[field] + row * 4, as: Float.self)
    }

    @inlinable public func bool(_ field: Int, _ row: Int) -> Bool {
        base.load(fromByteOffset: columnBaseOffset[field] + row, as: UInt8.self) != 0
    }

    @inlinable public func string(_ field: Int, _ row: Int) -> String {
        let span = stringFieldBase[field] + row * 2
        return ClickHouseUTF8.decode(UnsafeRawBufferPointer(start: base + stringSpans[span], count: stringSpans[span + 1]))
    }

    @inlinable public func bytes(_ field: Int, _ row: Int) -> [UInt8] {
        let span = stringFieldBase[field] + row * 2
        return Array(UnsafeRawBufferPointer(start: base + stringSpans[span], count: stringSpans[span + 1]))
    }
}
