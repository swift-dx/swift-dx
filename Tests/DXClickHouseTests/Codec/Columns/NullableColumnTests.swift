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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse nullable column")
struct NullableColumnTests {

    @Test("Nullable(String) round-trips with mixed null and present rows")
    func mixedNullsRoundTrip() throws {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .string),
            innerSpec: .string,
            nullMask: [false, true, false, false, true],
            inner: ClickHouseStringColumn(values: ["alpha", "", "gamma", "delta", ""])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 5 + (1 + 5) + 1 + (1 + 5) + (1 + 5) + 1)

        let decoded = try ClickHouseNullableColumn.decode(innerSpec: .string, rows: 5, from: &buffer)
        #expect(decoded.nullMask == [false, true, false, false, true])
        let inner = try #require(decoded.inner as? ClickHouseStringColumn)
        #expect(inner.values == ["alpha", "", "gamma", "delta", ""])
    }

    @Test("Nullable with all rows null preserves the mask")
    func allNullsRoundTrip() throws {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: [true, true, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [0, 0, 0])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseNullableColumn.decode(innerSpec: .int32, rows: 3, from: &buffer)
        #expect(decoded.nullMask == [true, true, true])
        let inner = try #require(decoded.inner as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(inner.rowCount == 3)
    }

    @Test("Nullable with no rows null preserves the dense values")
    func noNullsPreservesValues() throws {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .int64),
            innerSpec: .int64,
            nullMask: [false, false, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [-1, 0, 1])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseNullableColumn.decode(innerSpec: .int64, rows: 3, from: &buffer)
        let inner = try #require(decoded.inner as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(inner.values == [-1, 0, 1])
    }

    @Test("encode rejects an inner column whose row count diverges from the mask")
    func divergentInnerRowCountRejected() {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: [false, true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2])
        )
        var buffer = ByteBuffer()
        #expect {
            try column.encode(into: &buffer)
        } throws: { error in
            guard case ClickHouseError.nullableInnerRowCountMismatch(let expected, let actual) = error else {
                return false
            }
            return expected == 3 && actual == 2
        }
    }

    @Test("zero-row Nullable consumes zero bytes")
    func zeroRowsIsNoOp() throws {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: [],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseNullableColumn.decode(innerSpec: .int32, rows: 0, from: &buffer)
        #expect(decoded.nullMask.isEmpty)
        #expect(decoded.rowCount == 0)
    }

    @Test("registry decode of Nullable preserves the inner spec")
    func registryDispatchPreservesInnerSpec() throws {
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .string),
            innerSpec: .string,
            nullMask: [false, true],
            inner: ClickHouseStringColumn(values: ["x", ""])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .nullable(of: .string), rows: 2, from: &buffer)
        let typed = try #require(decoded as? ClickHouseNullableColumn)
        #expect(typed.innerSpec == .string)
        #expect(typed.spec == .nullable(of: .string))
    }

    @Test("a 100 000-row Nullable(Int32) round-trips byte-for-byte (covers bulk-write null-mask path)")
    func largeRowCountRoundTripPreservesEveryByte() throws {
        // Pseudo-random null pattern across 100k rows. The encoder
        // writes the null mask as a contiguous span of mask bytes; a
        // regression in the bulk-write path (e.g., a stride bug) would
        // surface as a byte-level decode mismatch.
        let count = 100_000
        var rng = SeededRandomNumberGenerator(seed: 0xA1_B2_C3_D4_E5_F6_07_08)
        var nullMask = [Bool]()
        nullMask.reserveCapacity(count)
        var values = [Int32]()
        values.reserveCapacity(count)
        for index in 0..<count {
            let isNull = (rng.next() & 0x07) == 0  // ~12.5% null density
            nullMask.append(isNull)
            values.append(isNull ? 0 : Int32(truncatingIfNeeded: index))
        }

        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: nullMask,
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
        )

        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        // Wire size: count mask bytes + count * 4 inner bytes.
        #expect(buffer.readableBytes == count + count * 4)

        let decoded = try ClickHouseNullableColumn.decode(innerSpec: .int32, rows: count, from: &buffer)
        #expect(decoded.nullMask == nullMask)
        let inner = try #require(decoded.inner as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(inner.values == values)
        #expect(buffer.readableBytes == 0, "decoder must consume the entire encoded payload")
    }

}
