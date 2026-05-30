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
import Testing

@Suite("ClickHouse insert conversion (typed values → typed columns)")
struct ClickHouseInsertConversionTests {

    @Test("Int32 values convert to a FixedWidthInteger column with the same values")
    func int32ConvertsToInt32Column() throws {
        let column = try ClickHouseClient.toInternalColumn(.int32([10, 20, 30]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [10, 20, 30])
        #expect(typed.spec == .int32)
    }

    @Test("String values convert to a String column with the same values")
    func stringConvertsToStringColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.string(["a", "b", "c"]))
        let typed = try #require(column as? ClickHouseStringColumn)
        #expect(typed.values == ["a", "b", "c"])
    }

    @Test("Date converts to a UInt16 days-since-epoch column")
    func dateConvertsToUInt16Days() throws {
        let day0 = Date(timeIntervalSince1970: 0)
        let day1 = Date(timeIntervalSince1970: 86_400)
        let day10 = Date(timeIntervalSince1970: 10 * 86_400)
        let column = try ClickHouseClient.toInternalColumn(.date([day0, day1, day10]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt16>)
        #expect(typed.values == [0, 1, 10])
        #expect(typed.spec == .date)
    }

    @Test("Date pre-1970 throws dateValueOutOfRange")
    func datePreEpochThrows() {
        let preEpoch = Date(timeIntervalSince1970: -1)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.date([preEpoch]))
        }
    }

    @Test("Date32 supports negative days (pre-1970) without overflow")
    func date32AcceptsNegativeDays() throws {
        let preEpoch = Date(timeIntervalSince1970: -86_400 * 1000)
        let column = try ClickHouseClient.toInternalColumn(.date32([preEpoch]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [-1000])
        #expect(typed.spec == .date32)
    }

    @Test("DateTime converts to a UInt32 seconds-since-epoch column")
    func dateTimeConvertsToUInt32Seconds() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let column = try ClickHouseClient.toInternalColumn(.dateTime([date]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(typed.values == [1_700_000_000])
        if case .dateTime(let timezone) = typed.spec {
            #expect(timezone == .serverDefault)
        } else {
            Issue.record("expected .dateTime spec, got \(typed.spec)")
        }
    }

    @Test("DateTime64 with precision 3 converts to a milliseconds column")
    func dateTime64Precision3ConvertsToMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let column = try ClickHouseClient.toInternalColumn(.dateTime64([date], precision: 3))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [1_700_000_000_123])
    }

    @Test("DateTime64 with precision 9 converts to a nanoseconds column")
    func dateTime64Precision9ConvertsToNanoseconds() throws {
        let date = Date(timeIntervalSince1970: 1.5)
        let column = try ClickHouseClient.toInternalColumn(.dateTime64([date], precision: 9))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [1_500_000_000])
    }

    @Test("DateTime64 with invalid precision (out of 0...9) throws invalidDateTime64Precision")
    func dateTime64InvalidPrecisionThrows() {
        let date = Date()
        #expect(throws: ClickHouseError.invalidDateTime64Precision(12)) {
            try ClickHouseClient.toInternalColumn(.dateTime64([date], precision: 12))
        }
        #expect(throws: ClickHouseError.invalidDateTime64Precision(-1)) {
            try ClickHouseClient.toInternalColumn(.dateTime64([date], precision: -1))
        }
    }

    // MARK: - Year-2106 / UInt32-seconds DateTime boundary

    @Test("DateTime accepts the exact UInt32.max seconds (2106-02-07 06:28:15 UTC) — last representable instant")
    func dateTimeAtExactUInt32MaxBoundary() throws {
        // Unix-time 4294967295 = 2106-02-07 06:28:15 UTC. The encoder
        // must accept this exact value and produce UInt32.max as the
        // wire form. Off-by-one rejection here would break a service
        // that legitimately stores future timestamps near the boundary.
        let date = Date(timeIntervalSince1970: 4_294_967_295)
        let column = try ClickHouseClient.toInternalColumn(.dateTime([date]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(typed.values == [UInt32.max])
    }

    @Test("DateTime rejects one second past UInt32.max with dateValueOutOfRange")
    func dateTimeOnePastUInt32MaxRejected() {
        // Unix-time 4294967296 = the second immediately past the
        // representable range. Must surface as a typed error rather
        // than silently truncate.
        let date = Date(timeIntervalSince1970: 4_294_967_296)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.dateTime([date]))
        }
    }

    @Test("DateTime accepts year 2105 (well within UInt32 range) and produces the correct unix-time wire value")
    func dateTimeYear2105() throws {
        // 2105-01-01 00:00:00 UTC — common production "future date"
        // case. Unix-time = 4259347200. Asserts correct projection
        // mid-range of the UInt32 representation.
        let date = Date(timeIntervalSince1970: 4_259_347_200)
        let column = try ClickHouseClient.toInternalColumn(.dateTime([date]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(typed.values == [4_259_347_200])
    }

    // MARK: - UInt16-days Date boundary (year 2149)

    @Test("Date accepts the exact UInt16.max days (2149-06-06 UTC) — last representable Date")
    func dateAtExactUInt16MaxDayBoundary() throws {
        // 65535 days × 86400 s = 5662224000 unix-seconds = 2149-06-06
        // 00:00:00 UTC. floor(5662224000 / 86400) = 65535 = UInt16.max.
        let date = Date(timeIntervalSince1970: 5_662_224_000)
        let column = try ClickHouseClient.toInternalColumn(.date([date]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt16>)
        #expect(typed.values == [UInt16.max])
    }

    @Test("Date rejects 2149-06-07 and beyond (one day past UInt16.max) with dateValueOutOfRange")
    func dateOneDayPastUInt16MaxRejected() {
        // 65536 days × 86400 = 5662310400 unix-seconds = 2149-06-07.
        let date = Date(timeIntervalSince1970: 5_662_310_400)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.date([date]))
        }
    }

    @Test("DateTime64 ticks at the Int64.max Double-rounded boundary throws cleanly (no Int64 overflow trap)")
    func dateTime64Int64MaxBoundaryDoesNotTrap() {
        // `Double(Int64.max)` rounds up to 2^63 = Int64.max + 1. A `ticks`
        // value at exactly that representation, before this fix, passed
        // the `<=` upper-bound guard but trapped during the `Int64(ticks)`
        // conversion. The fix uses strict `<` on the upper bound so the
        // trap is unreachable.
        //
        // Trigger: pick a date whose seconds × scale == 2^63 in Double.
        // 2^63 = 9.223372036854776e18; with precision 9 (scale = 1e9),
        // this corresponds to 9.223372036854776e9 seconds since epoch.
        let trapEdgeSeconds = 9_223_372_036.854_776
        let edgeDate = Date(timeIntervalSince1970: trapEdgeSeconds)
        // Must throw a typed error rather than abort the process.
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.dateTime64([edgeDate], precision: 9))
        }
    }

    @Test("FixedString with matching length converts to a FixedString column")
    func fixedStringMatchingLengthConverts() throws {
        let datas = [
            Data([0x01, 0x02, 0x03, 0x04]),
            Data([0xAA, 0xBB, 0xCC, 0xDD]),
        ]
        let column = try ClickHouseClient.toInternalColumn(.fixedString(length: 4, datas))
        let typed = try #require(column as? ClickHouseFixedStringColumn)
        #expect(typed.values == datas)
        #expect(typed.length == 4)
    }

    @Test("FixedString with mismatched length throws fixedStringLengthMismatch with the offending sizes")
    func fixedStringMismatchedLengthThrows() {
        #expect {
            try ClickHouseClient.toInternalColumn(.fixedString(length: 4, [Data([0x01, 0x02])]))
        } throws: { error in
            guard case ClickHouseError.fixedStringLengthMismatch(let expected, let actual) = error else {
                return false
            }
            return expected == 4 && actual == 2
        }
    }

    @Test("Array(String) builds cumulative offsets and a flattened inner String column")
    func arrayOfStringBuildsOffsetsAndInner() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfString([
            ["a", "b"],
            [],
            ["c", "d", "e"],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 2, 5])
        let inner = try #require(typed.inner as? ClickHouseStringColumn)
        #expect(inner.values == ["a", "b", "c", "d", "e"])
        #expect(typed.spec == .array(of: .string))
    }

    @Test("Array(Int64) flattens correctly across non-uniform row sizes")
    func arrayOfInt64Flattens() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfInt64([
            [Int64.max, -1],
            [0],
            [],
            [Int64.min],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 3, 3, 4])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(inner.values == [Int64.max, -1, 0, Int64.min])
    }

    @Test("Nullable(String) builds a null mask and uses empty-string sentinel for nulls")
    func nullableStringBuildsMaskAndSentinel() throws {
        let column = try ClickHouseClient.toInternalColumn(.nullableString([
            "alpha",
            nil,
            "gamma",
            nil,
            "",
        ]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false, true, false])
        let inner = try #require(typed.inner as? ClickHouseStringColumn)
        #expect(inner.values == ["alpha", "", "gamma", "", ""])
        #expect(typed.spec == .nullable(of: .string))
    }

    @Test("Nullable(Int32) uses 0 as sentinel and the mask preserves null positions")
    func nullableInt32UsesZeroSentinel() throws {
        let column = try ClickHouseClient.toInternalColumn(.nullableInt32([10, nil, -5, nil, 0]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(inner.values == [10, 0, -5, 0, 0])
    }

    @Test("IPv4 packed UInt32 values pass through to a UInt32 column with the IPv4 spec")
    func ipv4PassesThroughAsUInt32ColumnWithIPv4Spec() throws {
        let packed192_168_1_1: UInt32 = (192 << 24) | (168 << 16) | (1 << 8) | 1
        let packed10_0_0_1: UInt32 = (10 << 24) | (0 << 16) | (0 << 8) | 1
        let column = try ClickHouseClient.toInternalColumn(.ipv4([packed192_168_1_1, packed10_0_0_1]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(typed.values == [packed192_168_1_1, packed10_0_0_1])
        #expect(typed.spec == .ipv4)
    }

    @Test("IPv6 with correctly-sized 16-byte rows passes through as a FixedString column with the IPv6 spec")
    func ipv6PassesThroughWithIPv6Spec() throws {
        let address1 = Data((0..<16).map { UInt8($0) })
        let address2 = Data(repeating: 0xFF, count: 16)
        let column = try ClickHouseClient.toInternalColumn(.ipv6([address1, address2]))
        let typed = try #require(column as? ClickHouseFixedStringColumn)
        #expect(typed.length == 16)
        #expect(typed.values == [address1, address2])
        #expect(typed.spec == .ipv6)
    }

    @Test("IPv6 with a non-16-byte row throws fixedStringLengthMismatch with the offending size")
    func ipv6WithWrongSizeThrows() {
        let badAddress = Data([0x01, 0x02, 0x03, 0x04])
        #expect {
            try ClickHouseClient.toInternalColumn(.ipv6([badAddress]))
        } throws: { error in
            guard case ClickHouseError.fixedStringLengthMismatch(let expected, let actual) = error else {
                return false
            }
            return expected == 16 && actual == 4
        }
    }

    @Test("Nullable(UUID) preserves the null mask and uses a sentinel UUID for nulls")
    func nullableUUIDPreservesMask() throws {
        let real = try #require(UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F"))
        let column = try ClickHouseClient.toInternalColumn(.nullableUUID([.present(real), nil, .present(real), nil]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false, true])
        let inner = try #require(typed.inner as? ClickHouseUUIDColumn)
        #expect(inner.values.count == 4)
        #expect(inner.values[0] == real)
        #expect(inner.values[2] == real)
    }

    @Test("Nullable(Date) converts each present Date to UInt16 days and uses 0 sentinel for nulls")
    func nullableDateConvertsToDays() throws {
        let day10 = Date(timeIntervalSince1970: 10 * 86_400)
        let day100 = Date(timeIntervalSince1970: 100 * 86_400)
        let column = try ClickHouseClient.toInternalColumn(.nullableDate([.present(day10), nil, .present(day100)]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<UInt16>)
        #expect(inner.values == [10, 0, 100])
    }

    @Test("Nullable(DateTime) converts each present Date to UInt32 seconds and uses 0 sentinel for nulls")
    func nullableDateTimeConvertsToSeconds() throws {
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_800_000_000)
        let column = try ClickHouseClient.toInternalColumn(.nullableDateTime([.present(date1), nil, .present(date2)]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(inner.values == [1_700_000_000, 0, 1_800_000_000])
    }

    @Test("Nullable(Bool) preserves the null mask and uses false as sentinel")
    func nullableBoolPreservesMask() throws {
        let column = try ClickHouseClient.toInternalColumn(.nullableBool([true, nil, false, nil, true]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false, true, false])
        let inner = try #require(typed.inner as? ClickHouseBoolColumn)
        #expect(inner.values == [true, false, false, false, true])
    }

    @Test("Array(UUID) flattens correctly across non-uniform row sizes")
    func arrayOfUUIDFlattens() throws {
        let u1 = UUID()
        let u2 = UUID()
        let u3 = UUID()
        let column = try ClickHouseClient.toInternalColumn(.arrayOfUUID([
            [u1, u2],
            [],
            [u3],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 2, 3])
        let inner = try #require(typed.inner as? ClickHouseUUIDColumn)
        #expect(inner.values == [u1, u2, u3])
    }

    @Test("Array(Bool) flattens with mixed row sizes")
    func arrayOfBoolFlattens() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfBool([
            [true, false],
            [true],
            [],
            [false, false, true],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 3, 3, 6])
        let inner = try #require(typed.inner as? ClickHouseBoolColumn)
        #expect(inner.values == [true, false, true, false, false, true])
    }

    @Test("Map(String, Int32) builds parallel keys/values columns of the right sizes")
    func mapStringInt32BuildsParallelColumns() throws {
        let column = try ClickHouseClient.toInternalColumn(.mapStringInt32([
            ["a": 1, "b": 2],
            [:],
            ["c": 3],
        ]))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.offsets == [2, 2, 3])
        let keys = try #require(typed.keys as? ClickHouseStringColumn)
        let values = try #require(typed.values as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(keys.values.count == 3)
        #expect(values.values.count == 3)
    }

    @Test("Map(String, Int64) builds the right map spec and parallel columns")
    func mapStringInt64BuildsCorrectSpec() throws {
        let column = try ClickHouseClient.toInternalColumn(.mapStringInt64([
            ["x": Int64.max, "y": Int64.min],
        ]))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.offsets == [2])
        #expect(typed.spec == .map(key: .string, value: .int64))
    }

    @Test("Array(Float64) flattens metric-series rows correctly")
    func arrayOfFloat64FlattensMetricSeries() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfFloat64([
            [1.5, 2.5, 3.5],
            [],
            [-Float64.infinity, Float64.infinity],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [3, 3, 5])
        let inner = try #require(typed.inner as? ClickHouseFloat64Column)
        #expect(inner.values.count == 5)
        #expect(inner.values[0] == 1.5)
        #expect(inner.values[3] == -Float64.infinity)
        #expect(inner.values[4] == Float64.infinity)
    }

    @Test("Array(Float32) preserves NaN and infinity values across the flatten")
    func arrayOfFloat32PreservesSpecialValues() throws {
        let nan = Float32.nan
        let column = try ClickHouseClient.toInternalColumn(.arrayOfFloat32([
            [1.0, nan],
            [Float32.infinity],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        let inner = try #require(typed.inner as? ClickHouseFloat32Column)
        #expect(inner.values[0] == 1.0)
        #expect(inner.values[1].isNaN)
        #expect(inner.values[2] == Float32.infinity)
    }

    @Test("Array(Date) converts each row's Dates to UInt16 days through the array spec")
    func arrayOfDateConvertsToDaysColumn() throws {
        let day10 = Date(timeIntervalSince1970: 10 * 86_400)
        let day20 = Date(timeIntervalSince1970: 20 * 86_400)
        let column = try ClickHouseClient.toInternalColumn(.arrayOfDate([
            [day10, day20],
            [day10],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.offsets == [2, 3])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<UInt16>)
        #expect(inner.values == [10, 20, 10])
        #expect(typed.spec == .array(of: .date))
    }

    @Test("Array(DateTime) converts each row's Dates to UInt32 seconds through the array spec")
    func arrayOfDateTimeConvertsToSecondsColumn() throws {
        let date1 = Date(timeIntervalSince1970: 1_000)
        let date2 = Date(timeIntervalSince1970: 2_000)
        let column = try ClickHouseClient.toInternalColumn(.arrayOfDateTime([
            [date1, date2, date1],
        ]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(inner.values == [1_000, 2_000, 1_000])
    }

    @Test("Array(Date) propagates a date-out-of-range error from the inner conversion")
    func arrayOfDatePropagatesOutOfRangeError() {
        let preEpoch = Date(timeIntervalSince1970: -86_400)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.arrayOfDate([[preEpoch]]))
        }
    }

    @Test("Nullable(Float64) preserves the null mask and uses 0 as sentinel")
    func nullableFloat64PreservesMask() throws {
        let column = try ClickHouseClient.toInternalColumn(.nullableFloat64([1.5, nil, -2.5, nil, 0.0]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.nullMask == [false, true, false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFloat64Column)
        #expect(inner.values == [1.5, 0.0, -2.5, 0.0, 0.0])
    }

    @Test("Tuple(String, String) builds two parallel string columns sharing rowCount")
    func tupleStringStringBuildsParallelColumns() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleStringString([
            ("k1", "v1"),
            ("k2", "v2"),
            ("k3", "v3"),
        ]))
        let typed = try #require(column as? ClickHouseTupleColumn)
        #expect(typed.rowCount == 3)
        #expect(typed.elementSpecs == [.string, .string])
        #expect(typed.spec == .tuple(elements: [.string, .string]))
        let firstColumn = try #require(typed.elements[0] as? ClickHouseStringColumn)
        let secondColumn = try #require(typed.elements[1] as? ClickHouseStringColumn)
        #expect(firstColumn.values == ["k1", "k2", "k3"])
        #expect(secondColumn.values == ["v1", "v2", "v3"])
    }

    @Test("Tuple(String, Int32) preserves the typed integer column")
    func tupleStringInt32PreservesIntegerColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleStringInt32([
            ("requests", 100),
            ("errors", -1),
            ("bytes", Int32.max),
        ]))
        let typed = try #require(column as? ClickHouseTupleColumn)
        #expect(typed.rowCount == 3)
        let strings = try #require(typed.elements[0] as? ClickHouseStringColumn)
        let ints = try #require(typed.elements[1] as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(strings.values == ["requests", "errors", "bytes"])
        #expect(ints.values == [100, -1, Int32.max])
        #expect(typed.spec == .tuple(elements: [.string, .int32]))
    }

    @Test("Tuple(String, Int64) handles large 64-bit values")
    func tupleStringInt64HandlesLargeValues() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleStringInt64([
            ("max", Int64.max),
            ("min", Int64.min),
            ("zero", 0),
        ]))
        let typed = try #require(column as? ClickHouseTupleColumn)
        let ints = try #require(typed.elements[1] as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(ints.values == [Int64.max, Int64.min, 0])
        #expect(typed.spec == .tuple(elements: [.string, .int64]))
    }

    @Test("an empty Tuple(String, String) produces empty parallel columns with rowCount 0")
    func emptyTupleHasEmptyColumns() throws {
        let column = try ClickHouseClient.toInternalColumn(.tupleStringString([]))
        let typed = try #require(column as? ClickHouseTupleColumn)
        #expect(typed.rowCount == 0)
        let firstColumn = try #require(typed.elements[0] as? ClickHouseStringColumn)
        #expect(firstColumn.values.isEmpty)
    }

    @Test("LowCardinality(String) deduplicates and builds dictionary + indices")
    func lowCardinalityStringDedupes() throws {
        let column = try ClickHouseClient.toInternalColumn(.lowCardinalityString([
            "INFO", "WARN", "INFO", "ERROR", "INFO", "WARN",
        ]))
        let typed = try #require(column as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(typed.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == ["INFO", "WARN", "ERROR"])
        #expect(typed.indices == [0, 1, 0, 2, 0, 1])
        #expect(typed.spec == .lowCardinality(of: .string))
    }

    @Test("LowCardinality(String) with all unique values produces a dict the size of the input")
    func lowCardinalityStringAllUnique() throws {
        let values = (0..<10).map { "v\($0)" }
        let column = try ClickHouseClient.toInternalColumn(.lowCardinalityString(values))
        let typed = try #require(column as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(typed.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == values)
        #expect(typed.indices == (0..<10).map(UInt64.init))
    }

    @Test("Map(String, String) builds cumulative offsets and parallel keys/values columns")
    func mapStringStringBuildsParallelColumns() throws {
        let column = try ClickHouseClient.toInternalColumn(.mapStringString([
            ["k1": "v1", "k2": "v2"],
            [:],
            ["k3": "v3"],
        ]))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.offsets == [2, 2, 3])
        let keys = try #require(typed.keys as? ClickHouseStringColumn)
        let values = try #require(typed.values as? ClickHouseStringColumn)
        #expect(keys.values.count == 3)
        #expect(values.values.count == 3)
        let pairs = Set(zip(keys.values, values.values).map { "\($0):\($1)" })
        #expect(pairs.contains("k1:v1"))
        #expect(pairs.contains("k2:v2"))
        #expect(pairs.contains("k3:v3"))
    }

}
