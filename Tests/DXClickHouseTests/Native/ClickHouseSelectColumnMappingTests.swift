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

@Suite("ClickHouseSelectColumn — internal column to public Values mapping")
struct ClickHouseSelectColumnMappingTests {

    // MARK: - Integer types

    @Test("Int8 column maps to .int8 Values")
    func int8Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: [Int8.min, 0, Int8.max])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        #expect(publicColumn.name == "x")
        #expect(publicColumn.typeName == "Int8")
        guard case .int8(let values) = publicColumn.values else {
            Issue.record("expected .int8 case, got \(publicColumn.values)")
            return
        }
        #expect(values == [Int8.min, 0, Int8.max])
    }

    @Test("Int16/Int32/Int64 columns map to their respective Values cases")
    func signedIntegerMappings() throws {
        let int16Column = ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: [Int16.min, 0, Int16.max])
        let int32Column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [Int32.min, 0, Int32.max])
        let int64Column = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, 0, Int64.max])

        let int16Public = try ClickHouseSelectColumn.from(name: "a", internalColumn: int16Column)
        let int32Public = try ClickHouseSelectColumn.from(name: "b", internalColumn: int32Column)
        let int64Public = try ClickHouseSelectColumn.from(name: "c", internalColumn: int64Column)

        guard case .int16(let int16Values) = int16Public.values,
              case .int32(let int32Values) = int32Public.values,
              case .int64(let int64Values) = int64Public.values else {
            Issue.record("expected matching int cases")
            return
        }
        #expect(int16Values == [Int16.min, 0, Int16.max])
        #expect(int32Values == [Int32.min, 0, Int32.max])
        #expect(int64Values == [Int64.min, 0, Int64.max])
    }

    @Test("Int128 column maps to .int128 Values with boundary values preserved")
    func int128Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int128>(
            spec: .int128, values: [.min, 0, .max]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .int128(let values) = publicColumn.values else {
            Issue.record("expected .int128 case")
            return
        }
        #expect(values == [Int128.min, 0, Int128.max])
    }

    @Test("UInt8/16/32/64/128 columns map to their respective Values cases")
    func unsignedIntegerMappings() throws {
        let uint8Column = ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: [0, 1, UInt8.max])
        let uint16Column = ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .uint16, values: [0, 1, UInt16.max])
        let uint32Column = ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .uint32, values: [0, 1, UInt32.max])
        let uint64Column = ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [0, 1, UInt64.max])
        let uint128Column = ClickHouseFixedWidthIntegerColumn<UInt128>(spec: .uint128, values: [0, 1, .max])

        let uint8Public = try ClickHouseSelectColumn.from(name: "a", internalColumn: uint8Column)
        let uint16Public = try ClickHouseSelectColumn.from(name: "b", internalColumn: uint16Column)
        let uint32Public = try ClickHouseSelectColumn.from(name: "c", internalColumn: uint32Column)
        let uint64Public = try ClickHouseSelectColumn.from(name: "d", internalColumn: uint64Column)
        let uint128Public = try ClickHouseSelectColumn.from(name: "e", internalColumn: uint128Column)

        guard case .uint8(let v8) = uint8Public.values,
              case .uint16(let v16) = uint16Public.values,
              case .uint32(let v32) = uint32Public.values,
              case .uint64(let v64) = uint64Public.values,
              case .uint128(let v128) = uint128Public.values else {
            Issue.record("expected matching unsigned int cases")
            return
        }
        #expect(v8 == [0, 1, UInt8.max])
        #expect(v16 == [0, 1, UInt16.max])
        #expect(v32 == [0, 1, UInt32.max])
        #expect(v64 == [0, 1, UInt64.max])
        #expect(v128 == [0, 1, UInt128.max])
    }

    // MARK: - Floating point

    @Test("Float32 column maps to .float32 Values")
    func float32Mapping() throws {
        let column = ClickHouseFloat32Column(values: [0.0, .pi, -1.0])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .float32(let values) = publicColumn.values else {
            Issue.record("expected .float32 case")
            return
        }
        #expect(values == [0.0, .pi, -1.0])
    }

    @Test("Float64 column maps to .float64 Values")
    func float64Mapping() throws {
        let column = ClickHouseFloat64Column(values: [0.0, .pi, -.greatestFiniteMagnitude])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .float64(let values) = publicColumn.values else {
            Issue.record("expected .float64 case")
            return
        }
        #expect(values == [0.0, .pi, -.greatestFiniteMagnitude])
    }

    // MARK: - String, FixedString, Bool, UUID

    @Test("String column maps to .string Values")
    func stringMapping() throws {
        let column = ClickHouseStringColumn(values: ["a", "🇳🇿", ""])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .string(let values) = publicColumn.values else {
            Issue.record("expected .string case")
            return
        }
        #expect(values == ["a", "🇳🇿", ""])
    }

    @Test("FixedString(N) column maps to .fixedString Values with the original length")
    func fixedStringMapping() throws {
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 4), length: 4, values: [Data([0, 1, 2, 3]), Data([255, 255, 255, 255])]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .fixedString(let length, let values) = publicColumn.values else {
            Issue.record("expected .fixedString case")
            return
        }
        #expect(length == 4)
        #expect(values == [Data([0, 1, 2, 3]), Data([255, 255, 255, 255])])
    }

    @Test("Bool column maps to .bool Values")
    func boolMapping() throws {
        let column = ClickHouseBoolColumn(values: [true, false, true])
        let publicColumn = try ClickHouseSelectColumn.from(name: "flag", internalColumn: column)
        guard case .bool(let values) = publicColumn.values else {
            Issue.record("expected .bool case")
            return
        }
        #expect(values == [true, false, true])
    }

    @Test("UUID column maps to .uuid Values")
    func uuidMapping() throws {
        let identifiers: [UUID] = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        ]
        let column = ClickHouseUUIDColumn(values: identifiers)
        let publicColumn = try ClickHouseSelectColumn.from(name: "id", internalColumn: column)
        guard case .uuid(let values) = publicColumn.values else {
            Issue.record("expected .uuid case")
            return
        }
        #expect(values == identifiers)
    }

    // MARK: - Date / DateTime / DateTime64

    @Test("Date column (UInt16 days) maps to .date Values with Date conversion")
    func dateMapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: [0, 1, 100])
        let publicColumn = try ClickHouseSelectColumn.from(name: "d", internalColumn: column)
        guard case .date(let dates) = publicColumn.values else {
            Issue.record("expected .date case")
            return
        }
        #expect(dates[0] == Date(timeIntervalSince1970: 0))
        #expect(dates[1] == Date(timeIntervalSince1970: 86_400))
        #expect(dates[2] == Date(timeIntervalSince1970: 86_400 * 100))
    }

    @Test("Date32 column (Int32 days) maps to .date32 Values supporting negative offsets")
    func date32Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .date32, values: [-1, 0, 1])
        let publicColumn = try ClickHouseSelectColumn.from(name: "d", internalColumn: column)
        guard case .date32(let dates) = publicColumn.values else {
            Issue.record("expected .date32 case")
            return
        }
        #expect(dates[0] == Date(timeIntervalSince1970: -86_400))
        #expect(dates[1] == Date(timeIntervalSince1970: 0))
        #expect(dates[2] == Date(timeIntervalSince1970: 86_400))
    }

    @Test("DateTime column (UInt32 seconds) maps to .dateTime Values with second precision")
    func dateTimeMapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<UInt32>(
            spec: .dateTime(timezone: .serverDefault), values: [0, 1_700_000_000]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime(let dates) = publicColumn.values else {
            Issue.record("expected .dateTime case")
            return
        }
        #expect(dates[0] == Date(timeIntervalSince1970: 0))
        #expect(dates[1] == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("DateTime64 column (Int64 ticks at precision 3) maps to .dateTime64Nanoseconds normalized to ns")
    func dateTime64Mapping() throws {
        // precision 3 = milliseconds. Raw 1_700_000_000_500 ms = 1_700_000_000_500_000_000 ns
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 3, timezone: .serverDefault),
            values: [0, 1_700_000_000_500]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime64Nanoseconds(let nanos, let precision) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds case")
            return
        }
        #expect(precision == 3, "the original column precision is preserved")
        #expect(nanos[0].rawValue == 0)
        #expect(nanos[1].rawValue == 1_700_000_000_500_000_000, "ms ticks scaled to ns")
    }

    @Test("DateTime64 column with precision 9 preserves exact nanosecond ticks (no scaling)")
    func dateTime64NanosecondMapping() throws {
        // precision 9 = nanoseconds. Raw 1_700_000_000_000_000_001 ns = 1_700_000_000_000_000_001 ns
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 9, timezone: .serverDefault),
            values: [1_700_000_000_000_000_001]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .dateTime64Nanoseconds(let nanos, let precision) = publicColumn.values else {
            Issue.record("expected .dateTime64Nanoseconds case")
            return
        }
        #expect(precision == 9)
        #expect(nanos[0].rawValue == 1_700_000_000_000_000_001, "exact nanosecond preserved end-to-end")
    }

    @Test("DateTime64 column with a tick value that overflows tick × multiplier surfaces a typed error rather than crashing the SELECT")
    func dateTime64TickOverflowSurfacesTypedError() throws {
        // Pre-fix: `mapToValues` did `tick * multiplier` directly. For
        // precision 0 (multiplier = 10^9), any tick > ~9.22e9 (which
        // covers timestamps after roughly year 2262) overflows Int64
        // and traps the process — Swift signed integer * traps on
        // overflow. The fix detects overflow via
        // `multipliedReportingOverflow` and surfaces a typed error.
        // ClickHouse's DateTime64 supports up to year 2299, and some
        // applications use Int64.max as a sentinel "infinity" timestamp;
        // either case would crash a SELECT before this fix.
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 0, timezone: .serverDefault),
            values: [Int64.max]
        )
        #expect(throws: ClickHouseError.dateTime64TickToNanosecondsOverflow(ticks: Int64.max, precision: 0)) {
            _ = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        }
    }

    @Test("Nullable(DateTime64) with an overflowing tick value also surfaces a typed error rather than crashing — the nullable path was missed by the initial fix and crashed under the same input")
    func nullableDateTime64TickOverflowSurfacesTypedError() throws {
        // The non-nullable path's overflow guard didn't propagate to
        // `mapNullable`'s `.dateTime64` branch, leaving a symmetric trap
        // through the Nullable(DateTime64) column type. Same Int64.max
        // sentinel that would crash a non-nullable SELECT crashes a
        // nullable one too, in the same way (Swift signed * trap). The
        // fix mirrors the non-nullable guard.
        let inner = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 0, timezone: .serverDefault),
            values: [Int64.max, 0]
        )
        let nullable = ClickHouseNullableColumn(
            spec: .nullable(of: .dateTime64(precision: 0, timezone: .serverDefault)),
            innerSpec: .dateTime64(precision: 0, timezone: .serverDefault),
            nullMask: [false, true],
            inner: inner
        )
        #expect(throws: ClickHouseError.dateTime64TickToNanosecondsOverflow(ticks: Int64.max, precision: 0)) {
            _ = try ClickHouseSelectColumn.from(name: "ts", internalColumn: nullable)
        }
    }

    @Test("DateTime64 column with realistic future-dated tick (year 2262 boundary) at precision 0 still throws cleanly without crashing")
    func dateTime64FutureBoundaryAtSecondPrecisionThrows() throws {
        // tick = year 2280 in seconds since epoch ≈ 9_786_787_200; at
        // precision 0 this requires multiplying by 10^9, producing
        // ~9.79e18 which exceeds Int64.max (~9.22e18). The pre-fix code
        // would trap; the fix throws a clean typed error.
        let year2280InSeconds: Int64 = 9_786_787_200
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 0, timezone: .serverDefault),
            values: [year2280InSeconds]
        )
        #expect(throws: ClickHouseError.dateTime64TickToNanosecondsOverflow(ticks: year2280InSeconds, precision: 0)) {
            _ = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        }
    }

    // MARK: - Network types

    @Test("IPv4 column (UInt32) maps to .ipv4 Values preserving the raw uint32")
    func ipv4Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .ipv4, values: [0, 0x7F00_0001, UInt32.max])
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: column)
        guard case .ipv4(let values) = publicColumn.values else {
            Issue.record("expected .ipv4 case")
            return
        }
        #expect(values == [0, 0x7F00_0001, UInt32.max])
    }

    @Test("IPv6 column (FixedString of 16 bytes) maps to .ipv6 Values preserving raw bytes")
    func ipv6Mapping() throws {
        let loopback = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let zero = Data(repeating: 0, count: 16)
        let column = ClickHouseFixedStringColumn(spec: .ipv6, length: 16, values: [zero, loopback])
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: column)
        guard case .ipv6(let values) = publicColumn.values else {
            Issue.record("expected .ipv6 case")
            return
        }
        #expect(values == [zero, loopback])
    }

    // MARK: - Decimal

    @Test("Decimal32(scale) column maps to .decimal32 Values carrying scale")
    func decimal32Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .decimal32(scale: 4), values: [0, 12345, -67890])
        let publicColumn = try ClickHouseSelectColumn.from(name: "amt", internalColumn: column)
        guard case .decimal32(let values, let scale) = publicColumn.values else {
            Issue.record("expected .decimal32 case")
            return
        }
        #expect(scale == 4)
        #expect(values == [0, 12345, -67890])
    }

    @Test("Decimal64/128/256 columns carry scale through to public Values")
    func decimalAllSizesMapping() throws {
        let d64 = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .decimal64(scale: 6), values: [123_456_789])
        let d128 = ClickHouseFixedWidthIntegerColumn<Int128>(spec: .decimal128(scale: 18), values: [Int128.max])
        let d256 = ClickHouseInt256Column(spec: .decimal256(scale: 38), values: [.max])

        let d64Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: d64)
        let d128Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: d128)
        let d256Pub = try ClickHouseSelectColumn.from(name: "c", internalColumn: d256)

        guard case .decimal64(let v64, let s64) = d64Pub.values,
              case .decimal128(let v128, let s128) = d128Pub.values,
              case .decimal256(let v256, let s256) = d256Pub.values else {
            Issue.record("expected matching decimal cases")
            return
        }
        #expect(s64 == 6)
        #expect(s128 == 18)
        #expect(s256 == 38)
        #expect(v64 == [123_456_789])
        #expect(v128 == [Int128.max])
        #expect(v256 == [.max])
    }

    // MARK: - Time / Time64 / Interval

    @Test("Time column maps to .time Values (raw Int32 seconds-of-day)")
    func timeMapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .time, values: [0, 86_399, -3600])
        let publicColumn = try ClickHouseSelectColumn.from(name: "t", internalColumn: column)
        guard case .time(let values) = publicColumn.values else {
            Issue.record("expected .time case")
            return
        }
        #expect(values == [0, 86_399, -3600])
    }

    @Test("Time64(precision) column maps to .time64 Values carrying precision")
    func time64Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .time64(precision: 6), values: [0, 86_399_999_999])
        let publicColumn = try ClickHouseSelectColumn.from(name: "t", internalColumn: column)
        guard case .time64(let values, let precision) = publicColumn.values else {
            Issue.record("expected .time64 case")
            return
        }
        #expect(precision == 6)
        #expect(values == [0, 86_399_999_999])
    }

    @Test("Interval(kind) column maps to .interval Values carrying kind")
    func intervalMapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .interval(kind: .day), values: [0, 1, 365]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "i", internalColumn: column)
        guard case .interval(let kind, let values) = publicColumn.values else {
            Issue.record("expected .interval case")
            return
        }
        #expect(kind == .day)
        #expect(values == [0, 1, 365])
    }

    // MARK: - Wide types: Int256, UInt256, BFloat16

    @Test("Int256 column maps to .int256 Values preserving boundary values")
    func int256Mapping() throws {
        let column = ClickHouseInt256Column(spec: .int256, values: [.min, .zero, .max])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .int256(let values) = publicColumn.values else {
            Issue.record("expected .int256 case")
            return
        }
        #expect(values == [.min, .zero, .max])
    }

    @Test("UInt256 column maps to .uint256 Values preserving boundary values")
    func uint256Mapping() throws {
        let column = ClickHouseUInt256Column(spec: .uint256, values: [.zero, .max])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .uint256(let values) = publicColumn.values else {
            Issue.record("expected .uint256 case")
            return
        }
        #expect(values == [.zero, .max])
    }

    @Test("BFloat16 column maps to .bfloat16 Values")
    func bfloat16Mapping() throws {
        let column = ClickHouseBFloat16Column(spec: .bfloat16, values: [
            ClickHouseBFloat16(Float(0.5)), ClickHouseBFloat16(Float(-1.0)), .zero
        ])
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .bfloat16(let values) = publicColumn.values else {
            Issue.record("expected .bfloat16 case")
            return
        }
        #expect(values.count == 3)
    }

    // MARK: - Enum / JSON

    @Test("Enum8 column maps to .string Values with the per-row labels resolved from the spec")
    func enum8Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int8>(
            spec: .enum8([
                .init(name: "production", value: 1),
                .init(name: "staging", value: 2),
                .init(name: "development", value: 3),
            ]),
            values: [1, 2, 3, 1]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "env", internalColumn: column)
        guard case .string(let values) = publicColumn.values else {
            Issue.record("expected .string case carrying resolved labels for Enum8")
            return
        }
        #expect(values == ["production", "staging", "development", "production"])
    }

    @Test("Enum8 column with an unknown raw value falls back to the integer's string form rather than throwing")
    func enum8MappingUnknownValueFallback() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int8>(
            spec: .enum8([.init(name: "x", value: 1)]), values: [1, 99]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "e", internalColumn: column)
        guard case .string(let values) = publicColumn.values else {
            Issue.record("expected .string case")
            return
        }
        #expect(values == ["x", "99"])
    }

    @Test("Enum16 column maps to .string Values with the per-row labels resolved from the spec")
    func enum16Mapping() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int16>(
            spec: .enum16([
                .init(name: "alpha", value: 1000),
                .init(name: "beta", value: 1001),
            ]),
            values: [1000, 1001, 1000]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "e", internalColumn: column)
        guard case .string(let values) = publicColumn.values else {
            Issue.record("expected .string case carrying resolved labels for Enum16")
            return
        }
        #expect(values == ["alpha", "beta", "alpha"])
    }

    @Test("JSON column (String-backed) maps to .json Values")
    func jsonMapping() throws {
        let column = ClickHouseStringColumn(values: ["{\"a\":1}", "[]"])
        // JSON spec produces String column from the registry, but the public mapper needs the spec
        // information to know it's JSON. Since ClickHouseStringColumn carries .string spec, we
        // wrap with a synthetic spec by constructing a NamedColumn through a JSON path.
        // To exercise the .json case, we build it via the type-name parser.
        let jsonSpec = try ClickHouseTypeNameParser.parse("JSON")
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        let decoded = try ClickHouseColumnRegistry.decode(spec: jsonSpec, rows: 2, from: &buffer)
        let publicColumn = try ClickHouseSelectColumn.from(name: "j", internalColumn: decoded)
        #expect(publicColumn.typeName == "JSON")
        guard case .json(let values) = publicColumn.values else {
            Issue.record("expected .json case")
            return
        }
        #expect(values == ["{\"a\":1}", "[]"])
    }

    // MARK: - Unsupported composite types

    @Test("Array(Decimal128) throws unsupportedSelectColumnType — no Values case for that combination")
    func arrayOfDecimalThrowsUnsupported() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int128>(spec: .decimal128(scale: 18), values: [Int128(0), Int128(1), Int128(2)])
        let arrayColumn = ClickHouseArrayColumn(
            spec: .array(of: .decimal128(scale: 18)),
            elementSpec: .decimal128(scale: 18),
            offsets: [3],
            inner: inner
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "arr", internalColumn: arrayColumn)
        }
    }

    @Test("Nullable(Interval) throws unsupportedSelectColumnType — no Values case for that combination")
    func nullableIntervalThrowsUnsupported() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .interval(kind: .day), values: [0, 1])
        let nullableColumn = ClickHouseNullableColumn(
            spec: .nullable(of: .interval(kind: .day)),
            innerSpec: .interval(kind: .day),
            nullMask: [false, true],
            inner: inner
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "n", internalColumn: nullableColumn)
        }
    }

    // MARK: - End-to-end block construction

    @Test("ClickHouseClient.toSelectBlock maps an internal block with multiple columns to a public block")
    func selectBlockE2EMapping() throws {
        let intColumn = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        let stringColumn = ClickHouseStringColumn(values: ["a", "b", "c"])
        let block = ClickHouseBlock(
            blockInfo: ClickHouseBlockInfo(),
            columns: [
                .init(name: "id", column: intColumn),
                .init(name: "label", column: stringColumn)
            ]
        )
        let publicBlock = try ClickHouseClient.toSelectBlock(block)

        #expect(publicBlock.rowCount == 3)
        #expect(publicBlock.columns.count == 2)
        #expect(publicBlock.columns[0].name == "id")
        #expect(publicBlock.columns[1].name == "label")

        let idColumn = try publicBlock.requireColumn(named: "id")
        let labelColumn = try publicBlock.requireColumn(named: "label")
        guard case .int32(let ids) = idColumn.values, case .string(let labels) = labelColumn.values else {
            Issue.record("expected matching column shapes")
            return
        }
        #expect(ids == [1, 2, 3])
        #expect(labels == ["a", "b", "c"])
    }

    @Test("column(named:) returns .absent when the name is not present")
    func columnNamedReturnsAbsentWhenMissing() {
        let block = ClickHouseSelectBlock(rowCount: 0, columns: [])
        guard case .absent = block.column(named: "nope") else {
            Issue.record("expected .absent")
            return
        }
    }

    @Test("an empty block (zero columns) has rowCount 0")
    func emptyBlockHasZeroRows() {
        let block = ClickHouseSelectBlock(rowCount: 0, columns: [])
        #expect(block.rowCount == 0)
        #expect(block.columns.isEmpty)
    }

}
