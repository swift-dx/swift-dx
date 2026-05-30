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

@Suite("ClickHouseSelectColumn — Nullable(T) mapping")
struct ClickHouseSelectColumnNullableMappingTests {

    private static func makeNullable<T: ClickHouseColumn>(
        innerSpec: ClickHouseColumnSpec, mask: [Bool], inner: T
    ) -> ClickHouseNullableColumn {
        ClickHouseNullableColumn(
            spec: .nullable(of: innerSpec),
            innerSpec: innerSpec,
            nullMask: mask,
            inner: inner
        )
    }

    // MARK: - Integers

    @Test("Nullable(Int8) maps to .nullableInt8 with mask applied")
    func nullableInt8Mapping() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: [Int8.min, 0, Int8.max])
        let column = Self.makeNullable(innerSpec: .int8, mask: [false, true, false], inner: inner)
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .nullableInt8(let values) = publicColumn.values else {
            Issue.record("expected .nullableInt8 case")
            return
        }
        #expect(values.map(\.value) == [Int8.min, nil, Int8.max])
    }

    @Test("Nullable(Int16/Int32/Int64/Int128) preserve typed sentinel positions as nil")
    func nullableSignedIntegerMappings() throws {
        let int16 = Self.makeNullable(
            innerSpec: .int16, mask: [true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: [0, 42])
        )
        let int32 = Self.makeNullable(
            innerSpec: .int32, mask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [-1, 0])
        )
        let int64 = Self.makeNullable(
            innerSpec: .int64, mask: [false, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, Int64.max])
        )
        let int128 = Self.makeNullable(
            innerSpec: .int128, mask: [true, false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int128>(spec: .int128, values: [0, .max, 0])
        )

        let int16Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: int16)
        let int32Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: int32)
        let int64Pub = try ClickHouseSelectColumn.from(name: "c", internalColumn: int64)
        let int128Pub = try ClickHouseSelectColumn.from(name: "d", internalColumn: int128)

        guard case .nullableInt16(let v16) = int16Pub.values,
              case .nullableInt32(let v32) = int32Pub.values,
              case .nullableInt64(let v64) = int64Pub.values,
              case .nullableInt128(let v128) = int128Pub.values else {
            Issue.record("expected matching nullable cases")
            return
        }
        #expect(v16.map(\.value) == [nil, 42])
        #expect(v32.map(\.value) == [-1, nil])
        #expect(v64.map(\.value) == [Int64.min, Int64.max])
        #expect(v128.map(\.value) == [nil, Int128.max, nil])
    }

    @Test("Nullable(UInt8/16/32/64/128) preserve sentinel positions as nil")
    func nullableUnsignedIntegerMappings() throws {
        let uint8 = Self.makeNullable(
            innerSpec: .uint8, mask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: [255, 0])
        )
        let uint128 = Self.makeNullable(
            innerSpec: .uint128, mask: [true, false],
            inner: ClickHouseFixedWidthIntegerColumn<UInt128>(spec: .uint128, values: [0, .max])
        )

        let uint8Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: uint8)
        let uint128Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: uint128)

        guard case .nullableUInt8(let v8) = uint8Pub.values,
              case .nullableUInt128(let v128) = uint128Pub.values else {
            Issue.record("expected matching unsigned nullable cases")
            return
        }
        #expect(v8.map(\.value) == [255, nil])
        #expect(v128.map(\.value) == [nil, UInt128.max])
    }

    // MARK: - Floats

    @Test("Nullable(Float32/64) maps with mask applied")
    func nullableFloatMappings() throws {
        let f32 = Self.makeNullable(
            innerSpec: .float32, mask: [false, true],
            inner: ClickHouseFloat32Column(values: [.pi, 0])
        )
        let f64 = Self.makeNullable(
            innerSpec: .float64, mask: [true, false],
            inner: ClickHouseFloat64Column(values: [0, -.pi])
        )

        let f32Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: f32)
        let f64Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: f64)

        guard case .nullableFloat32(let v32) = f32Pub.values,
              case .nullableFloat64(let v64) = f64Pub.values else {
            Issue.record("expected matching float nullable cases")
            return
        }
        #expect(v32.map(\.value) == [.pi, nil])
        #expect(v64.map(\.value) == [nil, -.pi])
    }

    // MARK: - String / UUID / Bool

    @Test("Nullable(String) maps with mask applied")
    func nullableStringMapping() throws {
        let column = Self.makeNullable(
            innerSpec: .string, mask: [false, true, false],
            inner: ClickHouseStringColumn(values: ["alpha", "", "gamma"])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "s", internalColumn: column)
        guard case .nullableString(let values) = publicColumn.values else {
            Issue.record("expected .nullableString case")
            return
        }
        #expect(values.map(\.value) == ["alpha", nil, "gamma"])
    }

    @Test("Nullable(Bool) maps with mask applied")
    func nullableBoolMapping() throws {
        let column = Self.makeNullable(
            innerSpec: .bool, mask: [true, false, false],
            inner: ClickHouseBoolColumn(values: [false, true, false])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "b", internalColumn: column)
        guard case .nullableBool(let values) = publicColumn.values else {
            Issue.record("expected .nullableBool case")
            return
        }
        #expect(values.map(\.value) == [nil, true, false])
    }

    @Test("Nullable(UUID) maps with mask applied")
    func nullableUUIDMapping() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let column = Self.makeNullable(
            innerSpec: .uuid, mask: [false, true],
            inner: ClickHouseUUIDColumn(values: [id, UUID()])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "u", internalColumn: column)
        guard case .nullableUUID(let values) = publicColumn.values else {
            Issue.record("expected .nullableUUID case")
            return
        }
        #expect(values.map(\.value) == [id, nil])
    }

    // MARK: - Date / DateTime / DateTime64

    @Test("Nullable(Date) maps with Date conversion and mask applied")
    func nullableDateMapping() throws {
        let column = Self.makeNullable(
            innerSpec: .date, mask: [false, true, false],
            inner: ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: [0, 0, 100])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "d", internalColumn: column)
        guard case .nullableDate(let dates) = publicColumn.values else {
            Issue.record("expected .nullableDate case")
            return
        }
        #expect(dates[0].value == Date(timeIntervalSince1970: 0))
        #expect(dates[1] == nil)
        #expect(dates[2].value == Date(timeIntervalSince1970: 86_400 * 100))
    }

    @Test("Nullable(DateTime) maps with seconds-since-epoch conversion")
    func nullableDateTimeMapping() throws {
        let column = Self.makeNullable(
            innerSpec: .dateTime(timezone: .serverDefault), mask: [true, false],
            inner: ClickHouseFixedWidthIntegerColumn<UInt32>(
                spec: .dateTime(timezone: .serverDefault), values: [0, 1_700_000_000]
            )
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .nullableDateTime(let dates) = publicColumn.values else {
            Issue.record("expected .nullableDateTime case")
            return
        }
        #expect(dates.map(\.value) == [nil, Date(timeIntervalSince1970: 1_700_000_000)])
    }

    @Test("Nullable(Date32) preserves raw Int32 days (no Date conversion)")
    func nullableDate32Mapping() throws {
        let column = Self.makeNullable(
            innerSpec: .date32, mask: [false, true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .date32, values: [-1, 0, 1])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "d", internalColumn: column)
        guard case .nullableDate32(let values) = publicColumn.values else {
            Issue.record("expected .nullableDate32 case")
            return
        }
        #expect(values.map(\.value) == [-1, nil, 1])
    }

    @Test("Nullable(DateTime64) preserves precision and exact nanosecond ticks via .nullableDateTime64Nanoseconds")
    func nullableDateTime64Mapping() throws {
        let column = Self.makeNullable(
            innerSpec: .dateTime64(precision: 9, timezone: .serverDefault), mask: [false, true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(
                spec: .dateTime64(precision: 9, timezone: .serverDefault),
                values: [0, 0, 1_700_000_000_000_000_001]
            )
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .nullableDateTime64Nanoseconds(let values, let precision) = publicColumn.values else {
            Issue.record("expected .nullableDateTime64Nanoseconds case")
            return
        }
        #expect(precision == 9)
        #expect(values.count == 3)
        #expect(values[0].value?.rawValue == 0)
        #expect(values[1] == nil)
        #expect(values[2].value?.rawValue == 1_700_000_000_000_000_001, "trailing nanosecond preserved")
    }

    // MARK: - Decimal

    @Test("Nullable(Decimal32) carries scale and applies mask")
    func nullableDecimal32Mapping() throws {
        let column = Self.makeNullable(
            innerSpec: .decimal32(scale: 4), mask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .decimal32(scale: 4), values: [12345, 0])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "amt", internalColumn: column)
        guard case .nullableDecimal32(let values, let scale) = publicColumn.values else {
            Issue.record("expected .nullableDecimal32 case")
            return
        }
        #expect(scale == 4)
        #expect(values.map(\.value) == [12345, nil])
    }

    @Test("Nullable(Decimal64/128/256) carry scale and apply mask")
    func nullableDecimalAllSizesMapping() throws {
        let d64 = Self.makeNullable(
            innerSpec: .decimal64(scale: 6), mask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .decimal64(scale: 6), values: [123_456_789, 0])
        )
        let d128 = Self.makeNullable(
            innerSpec: .decimal128(scale: 18), mask: [true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int128>(spec: .decimal128(scale: 18), values: [0, .max])
        )
        let d256 = Self.makeNullable(
            innerSpec: .decimal256(scale: 38), mask: [false, true],
            inner: ClickHouseInt256Column(spec: .decimal256(scale: 38), values: [.max, .zero])
        )

        let d64Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: d64)
        let d128Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: d128)
        let d256Pub = try ClickHouseSelectColumn.from(name: "c", internalColumn: d256)

        guard case .nullableDecimal64(let v64, let s64) = d64Pub.values,
              case .nullableDecimal128(let v128, let s128) = d128Pub.values,
              case .nullableDecimal256(let v256, let s256) = d256Pub.values else {
            Issue.record("expected matching nullable decimal cases")
            return
        }
        #expect(s64 == 6)
        #expect(s128 == 18)
        #expect(s256 == 38)
        #expect(v64.map(\.value) == [123_456_789, nil])
        #expect(v128.map(\.value) == [nil, Int128.max])
        #expect(v256.map(\.value) == [.max, nil])
    }

    // MARK: - Wide ints

    @Test("Nullable(Int256/UInt256) map with mask applied")
    func nullable256BitMappings() throws {
        let int256 = Self.makeNullable(
            innerSpec: .int256, mask: [false, true, false],
            inner: ClickHouseInt256Column(spec: .int256, values: [.min, .zero, .max])
        )
        let uint256 = Self.makeNullable(
            innerSpec: .uint256, mask: [true, false],
            inner: ClickHouseUInt256Column(spec: .uint256, values: [.zero, .max])
        )

        let int256Pub = try ClickHouseSelectColumn.from(name: "a", internalColumn: int256)
        let uint256Pub = try ClickHouseSelectColumn.from(name: "b", internalColumn: uint256)

        guard case .nullableInt256(let v) = int256Pub.values,
              case .nullableUInt256(let u) = uint256Pub.values else {
            Issue.record("expected matching 256-bit nullable cases")
            return
        }
        #expect(v.map(\.value) == [.min, nil, .max])
        #expect(u.map(\.value) == [nil, .max])
    }

    // MARK: - Time / Time64 / BFloat16

    @Test("Nullable(Time) preserves raw Int32 seconds-of-day")
    func nullableTimeMapping() throws {
        let column = Self.makeNullable(
            innerSpec: .time, mask: [false, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .time, values: [86_399, 0])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "t", internalColumn: column)
        guard case .nullableTime(let values) = publicColumn.values else {
            Issue.record("expected .nullableTime case")
            return
        }
        #expect(values.map(\.value) == [86_399, nil])
    }

    @Test("Nullable(Time64) carries precision and applies mask")
    func nullableTime64Mapping() throws {
        let column = Self.makeNullable(
            innerSpec: .time64(precision: 6), mask: [true, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .time64(precision: 6), values: [0, 86_399_999_999])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "t", internalColumn: column)
        guard case .nullableTime64(let values, let precision) = publicColumn.values else {
            Issue.record("expected .nullableTime64 case")
            return
        }
        #expect(precision == 6)
        #expect(values.map(\.value) == [nil, 86_399_999_999])
    }

    @Test("Nullable(BFloat16) maps with mask applied")
    func nullableBFloat16Mapping() throws {
        let column = Self.makeNullable(
            innerSpec: .bfloat16, mask: [false, true, false],
            inner: ClickHouseBFloat16Column(spec: .bfloat16, values: [
                ClickHouseBFloat16(Float(0.5)), .zero, ClickHouseBFloat16(Float(-1.0))
            ])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "w", internalColumn: column)
        guard case .nullableBFloat16(let values) = publicColumn.values else {
            Issue.record("expected .nullableBFloat16 case")
            return
        }
        #expect(values.count == 3)
        #expect(values[1] == nil)
    }

    // MARK: - Edge cases

    @Test("an all-nil Nullable column returns all nil values")
    func allNilNullableColumn() throws {
        let column = Self.makeNullable(
            innerSpec: .int32, mask: [true, true, true, true, true],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [0, 0, 0, 0, 0])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .nullableInt32(let values) = publicColumn.values else {
            Issue.record("expected .nullableInt32 case")
            return
        }
        #expect(values.map(\.value) == [nil, nil, nil, nil, nil])
    }

    @Test("an all-present Nullable column returns no nils (every position is the inner value)")
    func allPresentNullableColumn() throws {
        let column = Self.makeNullable(
            innerSpec: .int32, mask: [false, false, false],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .nullableInt32(let values) = publicColumn.values else {
            Issue.record("expected .nullableInt32 case")
            return
        }
        #expect(values.map(\.value) == [1, 2, 3])
    }

    @Test("an empty Nullable column returns an empty array")
    func emptyNullableColumn() throws {
        let column = Self.makeNullable(
            innerSpec: .int32, mask: [],
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .nullableInt32(let values) = publicColumn.values else {
            Issue.record("expected .nullableInt32 case")
            return
        }
        #expect(values.isEmpty)
    }

    // MARK: - Wire round-trip

    @Test("Nullable(Int32) wire round-trips through encode/decode and the public mapper")
    func nullableInt32WireRoundTrip() throws {
        // Build an internal Nullable column with known values + mask
        let inner = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42, 0, -7, 0, 100])
        let mask: [Bool] = [false, true, false, true, false]
        let column = Self.makeNullable(innerSpec: .int32, mask: mask, inner: inner)

        // Encode to wire
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        // Decode from wire using the registry
        let decoded = try ClickHouseColumnRegistry.decode(spec: .nullable(of: .int32), rows: 5, from: &buffer)
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: decoded)

        guard case .nullableInt32(let values) = publicColumn.values else {
            Issue.record("expected .nullableInt32 case")
            return
        }
        #expect(values.map(\.value) == [42, nil, -7, nil, 100])
        #expect(buffer.readableBytes == 0, "all wire bytes consumed")
    }

}
