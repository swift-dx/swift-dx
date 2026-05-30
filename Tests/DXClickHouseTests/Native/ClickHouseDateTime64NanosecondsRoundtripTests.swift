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
import Foundation
import NIOCore
import Testing

@Suite("DateTime64 nanosecond fidelity — INSERT/SELECT round-trip via ClickHouseNanoseconds")
struct ClickHouseDateTime64NanosecondsRoundtripTests {

    // MARK: - INSERT side

    @Test("INSERT .dateTime64Nanoseconds at precision 9 stores the raw ns value as the ticks")
    func insertPrecision9PreservesTicks() throws {
        let nanos: [ClickHouseNanoseconds] = [
            ClickHouseNanoseconds(0),
            ClickHouseNanoseconds(1_700_000_000_000_000_001),
            ClickHouseNanoseconds(1_700_000_000_999_999_999)
        ]
        let internalColumn = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds(nanos, precision: 9))
        let typed = try #require(internalColumn as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [0, 1_700_000_000_000_000_001, 1_700_000_000_999_999_999], "no scaling at precision 9")
        #expect(typed.spec == .dateTime64(precision: 9, timezone: .serverDefault))
    }

    @Test("INSERT .dateTime64Nanoseconds at precision 6 (microseconds) divides ns by 1000")
    func insertPrecision6DividesByThousand() throws {
        let nanos: [ClickHouseNanoseconds] = [
            ClickHouseNanoseconds(1_700_000_000_123_456_789)
        ]
        let internalColumn = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds(nanos, precision: 6))
        let typed = try #require(internalColumn as? ClickHouseFixedWidthIntegerColumn<Int64>)
        // 1_700_000_000_123_456_789 ns / 1000 = 1_700_000_000_123_456 µs (truncates the trailing ".789")
        #expect(typed.values == [1_700_000_000_123_456])
    }

    @Test("INSERT .dateTime64Nanoseconds at precision 3 (milliseconds) divides ns by 1_000_000")
    func insertPrecision3DividesByMillion() throws {
        let nanos = [ClickHouseNanoseconds(1_700_000_000_123_456_789)]
        let internalColumn = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds(nanos, precision: 3))
        let typed = try #require(internalColumn as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [1_700_000_000_123])
    }

    @Test("INSERT .dateTime64Nanoseconds at precision 0 (whole seconds) divides ns by 1_000_000_000")
    func insertPrecision0DividesByBillion() throws {
        let nanos = [ClickHouseNanoseconds(1_700_000_000_999_999_999)]
        let internalColumn = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds(nanos, precision: 0))
        let typed = try #require(internalColumn as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [1_700_000_000])
    }

    // MARK: - SELECT side

    @Test("SELECT a precision-9 column returns nanos that match the raw Int64 ticks 1:1")
    func selectPrecision9MatchesRaw() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 9, timezone: .serverDefault),
            values: [1_700_000_000_000_000_001, 1_700_000_000_999_999_999]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime64Nanoseconds(let nanos, let precision) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds")
            return
        }
        #expect(precision == 9)
        #expect(nanos.map(\.rawValue) == [1_700_000_000_000_000_001, 1_700_000_000_999_999_999])
    }

    @Test("SELECT a precision-3 column scales ms ticks up to ns")
    func selectPrecision3ScalesUp() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 3, timezone: .serverDefault),
            values: [1_700_000_000_500]  // milliseconds → 1_700_000_000.500 sec
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime64Nanoseconds(let nanos, _) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds")
            return
        }
        #expect(nanos[0].rawValue == 1_700_000_000_500_000_000, "ms scaled to ns")
    }

    @Test("SELECT a precision-0 column scales whole seconds up to ns")
    func selectPrecision0ScalesUp() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 0, timezone: .serverDefault),
            values: [1_700_000_000]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime64Nanoseconds(let nanos, _) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds")
            return
        }
        #expect(nanos[0].rawValue == 1_700_000_000_000_000_000)
    }

    // MARK: - Full INSERT → wire → SELECT round-trip

    @Test("INSERT precision-9 nanos round-trip through wire encode/decode losslessly")
    func roundTripPrecision9() throws {
        let original: [ClickHouseNanoseconds] = [
            ClickHouseNanoseconds(0),
            ClickHouseNanoseconds(1_700_000_000_123_456_789),
            ClickHouseNanoseconds(1_700_000_000_999_999_999)
        ]
        let column = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds(original, precision: 9))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .dateTime64(precision: 9, timezone: .serverDefault), rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: decoded)
        guard case .dateTime64Nanoseconds(let restored, let precision) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds")
            return
        }
        #expect(precision == 9)
        #expect(restored.map(\.rawValue) == original.map(\.rawValue), "every nanosecond preserved end to end")
        #expect(buffer.readableBytes == 0)
    }

    // MARK: - Nullable INSERT side

    @Test("INSERT .nullableDateTime64Nanoseconds wraps the inner ticks column with the null mask")
    func insertNullableDateTime64Nanoseconds() throws {
        let optionals: [ClickHouseNanoseconds?] = [
            ClickHouseNanoseconds(1_700_000_000_000_000_001),
            nil,
            ClickHouseNanoseconds(1_700_000_000_999_999_999)
        ]
        let internalColumn = try ClickHouseClient.toInternalColumn(.nullableDateTime64Nanoseconds(optionals.map(ClickHouseNullable.init), precision: 9))
        let typed = try #require(internalColumn as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .dateTime64(precision: 9, timezone: .serverDefault)))
        #expect(typed.nullMask == [false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(inner.values[0] == 1_700_000_000_000_000_001)
        #expect(inner.values[2] == 1_700_000_000_999_999_999)
    }

    @Test("Nullable INSERT round-trips through wire encode/decode preserving every present nanosecond")
    func nullableRoundTrip() throws {
        let optionals: [ClickHouseNanoseconds?] = [
            nil,
            ClickHouseNanoseconds(1_700_000_000_500_000_001),
            nil,
            ClickHouseNanoseconds(1_700_000_001_999_999_999)
        ]
        let column = try ClickHouseClient.toInternalColumn(.nullableDateTime64Nanoseconds(optionals.map(ClickHouseNullable.init), precision: 9))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .nullable(of: .dateTime64(precision: 9, timezone: .serverDefault)),
            rows: optionals.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: decoded)
        guard case .nullableDateTime64Nanoseconds(let restored, let precision) = publicColumn.values else {
            Issue.record("expected .nullableDateTime64Nanoseconds")
            return
        }
        #expect(precision == 9)
        #expect(restored.count == 4)
        #expect(restored[0] == nil)
        #expect(restored[1].value?.rawValue == 1_700_000_000_500_000_001)
        #expect(restored[2] == nil)
        #expect(restored[3].value?.rawValue == 1_700_000_001_999_999_999)
        #expect(buffer.readableBytes == 0)
    }

    // MARK: - Sanity vs. the legacy Date-based path

    @Test("the new ns-bearing path preserves a value the legacy Date-based INSERT path would lose")
    func nanosecondPathBeatsDatePath() throws {
        let exactNs = ClickHouseNanoseconds(1_700_000_000_000_000_001)
        let viaNanos = try ClickHouseClient.toInternalColumn(.dateTime64Nanoseconds([exactNs], precision: 9))
        let typedNanos = try #require(viaNanos as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typedNanos.values[0] == 1_700_000_000_000_000_001, "exact via ns path")

        // The legacy Date-based path would round-trip through Double, losing the trailing nanosecond.
        let viaDate = try ClickHouseClient.toInternalColumn(.dateTime64([exactNs.date], precision: 9))
        let typedDate = try #require(viaDate as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typedDate.values[0] != typedNanos.values[0], "Date path is lossy at sub-microsecond — gap is real")
    }

    // MARK: - Pre-epoch (negative) tick floor convention

    @Test("INSERT .dateTime64Nanoseconds with -500_000_000 ns at precision 0 stores ticks of -1 (the second containing the moment), not 0 (the second AFTER the moment). Pre-fix: Swift's signed integer division truncates toward zero, so -500_000_000 / 1_000_000_000 yielded 0 — silently shifting any pre-epoch sub-second timestamp forward by one second. ch-go matches floor convention via Go's time.Time.Unix() which always floors.")
    func dateTime64NanosecondsFloorsNegativePrecision0() throws {
        let column = try ClickHouseClient.toInternalColumn(
            .dateTime64Nanoseconds([ClickHouseNanoseconds(-500_000_000)], precision: 0)
        )
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [-1],
                "negative pre-epoch ns must floor to the containing second, not truncate forward")
    }

    @Test("INSERT .dateTime64Nanoseconds with -1_500_000_000 ns at precision 0 stores ticks of -2 (1968-12-31 23:59:58 UTC), not -1 (which would represent the moment 1969-12-31 23:59:59 — half a second AFTER the actual input)")
    func dateTime64NanosecondsFloorsNegativeMultipleSeconds() throws {
        let column = try ClickHouseClient.toInternalColumn(
            .dateTime64Nanoseconds([ClickHouseNanoseconds(-1_500_000_000)], precision: 0)
        )
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [-2],
                "1.5 seconds before epoch must floor to -2 (second [-2, -1)), not truncate to -1")
    }

    @Test("INSERT .dateTime64Nanoseconds with -1_500_000 ns (1.5 ms before epoch) at precision 3 stores ticks of -2 ms, not -1 ms")
    func dateTime64NanosecondsFloorsNegativeAtMillisecondPrecision() throws {
        let column = try ClickHouseClient.toInternalColumn(
            .dateTime64Nanoseconds([ClickHouseNanoseconds(-1_500_000)], precision: 3)
        )
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [-2])
    }

    @Test("INSERT .nullableDateTime64Nanoseconds with -500_000_000 ns at precision 0 floors the present value to -1; nil entries remain nil. Symmetric to the non-nullable path so a Nullable(DateTime64) column doesn't silently shift pre-epoch values forward.")
    func nullableDateTime64NanosecondsFloorsNegative() throws {
        let optionals: [ClickHouseNanoseconds?] = [
            ClickHouseNanoseconds(-500_000_000),
            nil,
            ClickHouseNanoseconds(1_500_000_000)  // sanity: positive still OK
        ]
        let column = try ClickHouseClient.toInternalColumn(
            .nullableDateTime64Nanoseconds(optionals.map(ClickHouseNullable.init), precision: 0)
        )
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(inner.values[0] == -1, "negative pre-epoch ns must floor")
        // inner.values[1] is the sentinel (0) for the nil slot — value irrelevant to caller
        #expect(inner.values[2] == 1, "positive value untouched")
    }

    @Test("INSERT .dateTime64 (Date-based) with -0.5 sec Date at precision 0 stores ticks of -1, not 0. Symmetric concern to the nanosecond path: pre-fix `Int64(_:)` of a negative Double truncates toward zero, mapping -0.5 to 0 (1970-01-01 00:00:00 UTC) instead of -1 (1969-12-31 23:59:59 UTC). The Date32 / Date paths already use `floor(seconds / secondsPerDay)`, so the floor convention is the consistent choice across all date columns.")
    func dateTime64DateBasedFloorsNegativePrecision0() throws {
        let preEpoch = Date(timeIntervalSince1970: -0.5)
        let column = try ClickHouseClient.toInternalColumn(.dateTime64([preEpoch], precision: 0))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [-1],
                "Date(-0.5) at precision 0 must floor to the containing second")
    }

}
