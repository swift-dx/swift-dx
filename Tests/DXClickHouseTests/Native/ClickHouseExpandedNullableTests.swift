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

@Suite("ClickHouseClient — expanded Nullable variants for Decimal/Date/Time/Int128+/BFloat16")
struct ClickHouseExpandedNullableTests {

    // MARK: - Nullable Decimal

    @Test("nullableDecimal32 carries scale through to the inner spec")
    func nullableDecimal32CarriesScale() throws {
        let optionals: [Int32?] = [nil, 12_345, nil, -67_890]
        let column = try ClickHouseClient.toInternalColumn(.nullableDecimal32(optionals.map(ClickHouseNullable.init), scale: 4))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .decimal32(scale: 4)))
        #expect(typed.rowCount == 4)
    }

    @Test("nullableDecimal64 round-trips with explicit scale")
    func nullableDecimal64Conversion() throws {
        let optionals: [Int64?] = [nil, 999_999_999_999, 0]
        let column = try ClickHouseClient.toInternalColumn(.nullableDecimal64(optionals.map(ClickHouseNullable.init), scale: 6))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .decimal64(scale: 6)))
    }

    @Test("nullableDecimal128 round-trips with Int128 storage")
    func nullableDecimal128Conversion() throws {
        let optionals: [Int128?] = [nil, Int128.max, Int128.min, 0]
        let column = try ClickHouseClient.toInternalColumn(.nullableDecimal128(optionals.map(ClickHouseNullable.init), scale: 18))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .decimal128(scale: 18)))
    }

    @Test("nullableDecimal256 round-trips with ClickHouseInt256 storage")
    func nullableDecimal256Conversion() throws {
        let optionals: [ClickHouseInt256?] = [nil, .max, .min, .zero]
        let column = try ClickHouseClient.toInternalColumn(.nullableDecimal256(optionals.map(ClickHouseNullable.init), scale: 38))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .decimal256(scale: 38)))
    }

    // MARK: - Nullable Date32 / DateTime64

    @Test("nullableDate32 round-trips Int32-encoded dates")
    func nullableDate32Conversion() throws {
        let optionals: [Int32?] = [nil, 0, 18_628, -100_000, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableDate32(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .date32))
    }

    @Test("nullableDateTime64 carries precision through")
    func nullableDateTime64Conversion() throws {
        let optionals: [Int64?] = [nil, 1_700_000_000_000_000_000, nil]  // ns precision
        let column = try ClickHouseClient.toInternalColumn(.nullableDateTime64(optionals.map(ClickHouseNullable.init), precision: 9))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .dateTime64(precision: 9, timezone: .serverDefault)))
    }

    // MARK: - Nullable wide integers

    @Test("nullableInt128 round-trips boundary values")
    func nullableInt128Conversion() throws {
        let optionals: [Int128?] = [nil, .max, .min, 0, -1]
        let column = try ClickHouseClient.toInternalColumn(.nullableInt128(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .int128))
    }

    @Test("nullableUInt128 round-trips boundary values")
    func nullableUInt128Conversion() throws {
        let optionals: [UInt128?] = [nil, .max, 0, UInt128(UInt64.max)]
        let column = try ClickHouseClient.toInternalColumn(.nullableUInt128(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .uint128))
    }

    @Test("nullableInt256 round-trips boundary values")
    func nullableInt256Conversion() throws {
        let optionals: [ClickHouseInt256?] = [nil, .max, .min, .zero, ClickHouseInt256(Int64(42))]
        let column = try ClickHouseClient.toInternalColumn(.nullableInt256(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .int256))
    }

    @Test("nullableUInt256 round-trips boundary values")
    func nullableUInt256Conversion() throws {
        let optionals: [ClickHouseUInt256?] = [nil, .max, .zero]
        let column = try ClickHouseClient.toInternalColumn(.nullableUInt256(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .uint256))
    }

    // MARK: - Nullable Time / Time64

    @Test("nullableTime round-trips Int32 seconds-of-day values")
    func nullableTimeConversion() throws {
        let optionals: [Int32?] = [nil, 0, 86_399, -86_399]  // negative legacy support
        let column = try ClickHouseClient.toInternalColumn(.nullableTime(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .time))
    }

    @Test("nullableTime64 carries precision through")
    func nullableTime64Conversion() throws {
        let optionals: [Int64?] = [nil, 86_399_999_999, 0]  // microsecond precision
        let column = try ClickHouseClient.toInternalColumn(.nullableTime64(optionals.map(ClickHouseNullable.init), precision: 6))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .time64(precision: 6)))
    }

    // MARK: - Nullable BFloat16

    @Test("nullableBFloat16 round-trips for ML weight columns")
    func nullableBFloat16Conversion() throws {
        let optionals: [ClickHouseBFloat16?] = [
            nil,
            ClickHouseBFloat16(Float(0.5)),
            ClickHouseBFloat16(Float(-1.0)),
            nil,
            .zero
        ]
        let column = try ClickHouseClient.toInternalColumn(.nullableBFloat16(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .bfloat16))
        #expect(typed.rowCount == 5)
    }

    // MARK: - Cross-cutting: all-nil and empty cases

    @Test("an all-nil nullable Decimal column tracks the correct rowCount")
    func allNilDecimalTracksRowCount() throws {
        let optionals: [Int32?] = Array(repeating: nil, count: 7)
        let column = try ClickHouseClient.toInternalColumn(.nullableDecimal32(optionals.map(ClickHouseNullable.init), scale: 2))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == 7)
    }

    @Test("an empty nullable column produces a 0-row column for every new variant")
    func emptyNullablesAcrossNewVariants() throws {
        let cases: [(String, ClickHouseColumnEntry.Values)] = [
            ("decimal32", .nullableDecimal32([], scale: 2)),
            ("decimal64", .nullableDecimal64([], scale: 4)),
            ("decimal128", .nullableDecimal128([], scale: 18)),
            ("decimal256", .nullableDecimal256([], scale: 38)),
            ("date32", .nullableDate32([])),
            ("dateTime64", .nullableDateTime64([], precision: 3)),
            ("int128", .nullableInt128([])),
            ("uint128", .nullableUInt128([])),
            ("int256", .nullableInt256([])),
            ("uint256", .nullableUInt256([])),
            ("time", .nullableTime([])),
            ("time64", .nullableTime64([], precision: 6)),
            ("bfloat16", .nullableBFloat16([]))
        ]
        for (label, value) in cases {
            let column = try ClickHouseClient.toInternalColumn(value)
            let typed = try #require(column as? ClickHouseNullableColumn, "\(label): expected nullable column")
            #expect(typed.rowCount == 0, "\(label): expected 0-row")
        }
    }

}
