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

@Suite("ClickHouseClient — public API expansion (new Map and Array variants)")
struct ClickHousePublicAPIExpansionTests {

    // MARK: - Map variants

    @Test("public typed-INSERT API converts .mapStringFloat64 to a MapColumn with String→Float64 spec")
    func mapStringFloat64Conversion() throws {
        let dicts: [[String: Double]] = [
            ["temp_c": 23.5, "humidity_pct": 65.0],
            ["temp_c": 24.1]
        ]
        let column = try ClickHouseClient.toInternalColumn(.mapStringFloat64(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .string, value: .float64))
        #expect(typed.rowCount == 2)
        let keys = try #require(typed.keys as? ClickHouseStringColumn)
        let values = try #require(typed.values as? ClickHouseFloat64Column)
        #expect(keys.values.count == 3)
        #expect(values.values.count == 3)
    }

    @Test("public typed-INSERT API converts .mapStringBool")
    func mapStringBoolConversion() throws {
        let dicts: [[String: Bool]] = [
            ["feature_a": true, "feature_b": false],
            [:]
        ]
        let column = try ClickHouseClient.toInternalColumn(.mapStringBool(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .string, value: .bool))
        #expect(typed.rowCount == 2)
    }

    @Test("public typed-INSERT API converts .mapInt32String")
    func mapInt32StringConversion() throws {
        let dicts: [[Int32: String]] = [
            [1: "alice", 2: "bob"],
            [42: "charlie"]
        ]
        let column = try ClickHouseClient.toInternalColumn(.mapInt32String(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .int32, value: .string))
        #expect(typed.rowCount == 2)
    }

    @Test("public typed-INSERT API converts .mapInt64String")
    func mapInt64StringConversion() throws {
        let dicts: [[Int64: String]] = [
            [10_000_000_000: "huge_id"],
            [1: "small"]
        ]
        let column = try ClickHouseClient.toInternalColumn(.mapInt64String(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .int64, value: .string))
    }

    @Test("an empty Map column ([]) produces a 0-row column")
    func emptyMapColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.mapStringFloat64([]))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.rowCount == 0)
    }

    // MARK: - Array variants (mid-width ints + BFloat16)

    @Test("public typed-INSERT API converts .arrayOfInt8")
    func arrayOfInt8Conversion() throws {
        let arrays: [[Int8]] = [[1, 2, 3], [], [Int8.min, Int8.max]]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfInt8(arrays))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .int8))
        #expect(typed.rowCount == 3)
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<Int8>)
        #expect(inner.values == [1, 2, 3, Int8.min, Int8.max])
    }

    @Test("public typed-INSERT API converts .arrayOfInt16")
    func arrayOfInt16Conversion() throws {
        let arrays: [[Int16]] = [[100, 200], [-1]]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfInt16(arrays))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .int16))
    }

    @Test("public typed-INSERT API converts .arrayOfUInt8")
    func arrayOfUInt8Conversion() throws {
        let arrays: [[UInt8]] = [[0, 128, 255]]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfUInt8(arrays))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .uint8))
    }

    @Test("public typed-INSERT API converts .arrayOfUInt16")
    func arrayOfUInt16Conversion() throws {
        let arrays: [[UInt16]] = [[0, UInt16.max], [1024]]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfUInt16(arrays))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .uint16))
    }

    @Test("public typed-INSERT API converts .arrayOfBFloat16 — common ML weight array shape")
    func arrayOfBFloat16Conversion() throws {
        let arrays: [[ClickHouseBFloat16]] = [
            [ClickHouseBFloat16(Float(0.5)), ClickHouseBFloat16(Float(-0.25))],
            [ClickHouseBFloat16(Float(1.0))]
        ]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfBFloat16(arrays))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .bfloat16))
        #expect(typed.rowCount == 2)
        let inner = try #require(typed.inner as? ClickHouseBFloat16Column)
        #expect(inner.rowCount == 3)
    }

    // MARK: - Array of Tuple (Geographic Ring INSERT)

    @Test("public typed-INSERT API converts .arrayOfTupleFloat64Float64 — completes Geographic Ring INSERT")
    func arrayOfTupleFloat64Float64Conversion() throws {
        // Two rings: triangle and a 4-point quadrilateral.
        let rings: [[(Double, Double)]] = [
            [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)],
            [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        ]
        let column = try ClickHouseClient.toInternalColumn(.arrayOfTupleFloat64Float64(rings))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.spec == .array(of: .tuple(elements: [.float64, .float64])))
        #expect(typed.rowCount == 2)
        let innerTuple = try #require(typed.inner as? ClickHouseTupleColumn)
        #expect(innerTuple.rowCount == 7)  // 3 + 4 points

        let firsts = try #require(innerTuple.elements[0] as? ClickHouseFloat64Column)
        let seconds = try #require(innerTuple.elements[1] as? ClickHouseFloat64Column)
        #expect(firsts.values == [0.0, 1.0, 0.5, 0.0, 1.0, 1.0, 0.0])
        #expect(seconds.values == [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0])
    }

    @Test("an arrayOfTupleFloat64Float64 spec parses as Ring (Geographic alias) — INSERT and SELECT use the same internal spec")
    func arrayOfTupleMatchesRingAlias() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfTupleFloat64Float64([[(1.0, 2.0)]]))
        let ringSpec = try ClickHouseTypeNameParser.parse("Ring")
        #expect(column.spec == ringSpec, "INSERT-side spec must match the parsed Ring alias for SELECT-side compatibility")
    }

    @Test("an empty arrayOfTupleFloat64Float64 produces a 0-row array column")
    func emptyArrayOfTupleColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.arrayOfTupleFloat64Float64([]))
        let typed = try #require(column as? ClickHouseArrayColumn)
        #expect(typed.rowCount == 0)
    }

}
