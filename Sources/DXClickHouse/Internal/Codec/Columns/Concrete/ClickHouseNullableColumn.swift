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

// CH `Nullable(T)` wire layout:
//   - rows × 1-byte null mask (0 = present, 1 = null)
//   - the inner column with rows entries; positions where the mask is null
//     hold sentinel/zero values that callers must treat as absent.
//
// The mask and the inner column are independent — Swift's idiomatic
// `[T?]` is a semantic-layer projection over (mask, dense column), not
// the storage shape.
struct ClickHouseNullableColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let innerSpec: ClickHouseColumnSpec
    var nullMask: [Bool]
    var inner: any ClickHouseColumn

    var rowCount: Int { nullMask.count }

    func encodePrefix(into buffer: inout ByteBuffer) throws {
        try inner.encodePrefix(into: &buffer)
    }

    func encode(into buffer: inout ByteBuffer) throws {
        guard inner.rowCount == nullMask.count else {
            throw ClickHouseError.nullableInnerRowCountMismatch(
                expected: nullMask.count,
                actual: inner.rowCount
            )
        }
        // Write the null mask directly into the buffer's writable
        // region instead of N * `writeInteger(UInt8)` calls. Each
        // writeInteger goes through bounds checks and writer-index
        // updates; the bulk path does one bounds check and a tight
        // pointer-store loop, which is dramatically faster on large
        // columns and matches the pattern used by the fixed-width
        // integer codec.
        let count = nullMask.count
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: count) { rawBytes in
            let dst = rawBytes.bindMemory(to: UInt8.self)
            for i in 0..<count {
                dst[i] = nullMask[i] ? 1 : 0
            }
            return count
        }
        try inner.encode(into: &buffer)
    }

    static func decode(innerSpec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let nullMask = try readNullMask(rows: rows, from: &buffer)
        let inner = try ClickHouseColumnRegistry.decode(spec: innerSpec, rows: rows, from: &buffer)
        try requireInnerRowCount(inner: inner, expected: rows)
        return .init(
            spec: .nullable(of: innerSpec),
            innerSpec: innerSpec,
            nullMask: nullMask,
            inner: inner
        )
    }

    private static func readNullMask(rows: Int, from buffer: inout ByteBuffer) throws -> [Bool] {
        guard buffer.readableBytes >= rows else {
            throw ClickHouseError.truncatedBuffer(needed: rows, available: buffer.readableBytes)
        }
        var nullMask: [Bool] = []
        nullMask.reserveCapacity(rows)
        for _ in 0..<rows {
            nullMask.append(try readNullMaskByte(from: &buffer))
        }
        return nullMask
    }

    private static func readNullMaskByte(from buffer: inout ByteBuffer) throws -> Bool {
        guard let raw: UInt8 = buffer.readInteger() else {
            throw ClickHouseError.truncatedBuffer(needed: 1, available: buffer.readableBytes)
        }
        return raw != 0
    }

    private static func requireInnerRowCount(inner: any ClickHouseColumn, expected: Int) throws {
        guard inner.rowCount == expected else {
            throw ClickHouseError.nullableInnerRowCountMismatch(
                expected: expected,
                actual: inner.rowCount
            )
        }
    }

}
