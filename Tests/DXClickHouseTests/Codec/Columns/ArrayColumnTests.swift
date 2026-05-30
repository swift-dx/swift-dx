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

@Suite("ClickHouse array column")
struct ArrayColumnTests {

    @Test("Array(Int32) round-trips with mixed-size and empty rows")
    func arrayOfInt32MixedSizes() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int32>(
            spec: .int32,
            values: [10, 20, 30, 40, 50, 60]
        )
        let column = ClickHouseArrayColumn(
            spec: .array(of: .int32),
            elementSpec: .int32,
            offsets: [2, 3, 3, 6],
            inner: inner
        )

        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 4 * 8 + 6 * 4)

        let decoded = try ClickHouseArrayColumn.decode(elementSpec: .int32, rows: 4, from: &buffer)
        #expect(decoded.offsets == [2, 3, 3, 6])
        #expect(decoded.spec == .array(of: .int32))
        let decodedInner = try #require(decoded.inner as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(decodedInner.values == [10, 20, 30, 40, 50, 60])
        #expect(buffer.readableBytes == 0)
    }

    @Test("Array round-trip with zero rows consumes zero bytes")
    func zeroRowArray() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        let column = ClickHouseArrayColumn(
            spec: .array(of: .int32),
            elementSpec: .int32,
            offsets: [],
            inner: inner
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseArrayColumn.decode(elementSpec: .int32, rows: 0, from: &buffer)
        #expect(decoded.offsets.isEmpty)
        #expect(decoded.rowCount == 0)
    }

    @Test("Array with all empty rows produces zero inner elements")
    func allEmptyRows() throws {
        var buffer = ByteBuffer()
        let offsets: [UInt64] = [0, 0, 0]
        buffer.writeClickHouseFixedWidthIntegers(offsets)

        let decoded = try ClickHouseArrayColumn.decode(elementSpec: .int32, rows: 3, from: &buffer)
        #expect(decoded.offsets == [0, 0, 0])
        let inner = try #require(decoded.inner as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(inner.values.isEmpty)
    }

    @Test("non-monotonic offsets are rejected with the offending index identified")
    func nonMonotonicOffsetsRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([UInt64(2), UInt64(1), UInt64(5)])

        do {
            _ = try ClickHouseArrayColumn.decode(elementSpec: .int32, rows: 3, from: &buffer)
            Issue.record("expected non-monotonic offset error")
        } catch let ClickHouseError.nonMonotonicArrayOffsets(at, value, previous) {
            #expect(at == 1)
            #expect(value == 1)
            #expect(previous == 2)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("recursive Array(Nullable(String)) round-trips through the registry")
    func arrayOfNullableString() throws {
        let inner = ClickHouseNullableColumn(
            spec: .nullable(of: .string),
            innerSpec: .string,
            nullMask: [false, true, false, false],
            inner: ClickHouseStringColumn(values: ["a", "", "c", "d"])
        )
        let column = ClickHouseArrayColumn(
            spec: .array(of: .nullable(of: .string)),
            elementSpec: .nullable(of: .string),
            offsets: [2, 4],
            inner: inner
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .array(of: .nullable(of: .string)),
            rows: 2,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 4])

        let decodedNullable = try #require(typed.inner as? ClickHouseNullableColumn)
        #expect(decodedNullable.nullMask == [false, true, false, false])

        let decodedStrings = try #require(decodedNullable.inner as? ClickHouseStringColumn)
        #expect(decodedStrings.values == ["a", "", "c", "d"])
    }

    @Test("offset overflowing Int trips a typed error rather than allocating absurd memory")
    func absurdOffsetIsRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([UInt64.max])

        #expect(throws: ClickHouseError.self) {
            try ClickHouseArrayColumn.decode(elementSpec: .int32, rows: 1, from: &buffer)
        }
    }

    @Test("encode rejects an Array column whose inner row count disagrees with the last offset, instead of silently writing corrupt bytes")
    func encodeRejectsOffsetInnerMismatch() {
        // Manually construct a malformed ArrayColumn: offsets claim
        // the inner column should have 5 rows, but the inner column
        // actually has 3. Pre-fix the encoder would silently produce
        // corrupt wire bytes; post-fix it throws a typed error
        // symmetric with the decoder's existing check.
        let column = ClickHouseArrayColumn(
            spec: .array(of: .int32),
            elementSpec: .int32,
            offsets: [5],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        )
        var buffer = ByteBuffer()
        var thrown: Error?
        do {
            try column.encode(into: &buffer)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        #expect(
            received == .nullableInnerRowCountMismatch(expected: 5, actual: 3),
            "encoder must reject offset/inner mismatch with a typed error, got \(String(describing: thrown))"
        )
    }

    @Test("encode rejects non-monotonic offsets symmetric with decode (catches malformed columns client-side)")
    func encodeRejectsNonMonotonicOffsets() {
        // offsets [5, 3] is decreasing — decoder rejects on read with
        // `nonMonotonicArrayOffsets`. Encoder must reject the same shape
        // before sending bytes the server would refuse anyway. Inner
        // row count matches `offsets.last` to bypass the rowCount check
        // and isolate the monotonicity gate.
        let column = ClickHouseArrayColumn(
            spec: .array(of: .int32),
            elementSpec: .int32,
            offsets: [5, 3],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        )
        var buffer = ByteBuffer()
        var thrown: Error?
        do {
            try column.encode(into: &buffer)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        guard case .nonMonotonicArrayOffsets(let at, let value, let previous) = received ?? .poolHasNoEndpoints else {
            Issue.record("expected nonMonotonicArrayOffsets, got \(String(describing: thrown))")
            return
        }
        #expect(at == 1, "the offending index is the second offset")
        #expect(value == 3)
        #expect(previous == 5)
    }

}
