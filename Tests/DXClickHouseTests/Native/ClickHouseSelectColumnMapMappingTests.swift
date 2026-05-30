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

@Suite("ClickHouseSelectColumn — Map(K, V) mapping")
struct ClickHouseSelectColumnMapMappingTests {

    private static func makeMap<K: ClickHouseColumn, V: ClickHouseColumn>(
        keySpec: ClickHouseColumnSpec, valueSpec: ClickHouseColumnSpec,
        offsets: [UInt64], keys: K, values: V
    ) -> ClickHouseMapColumn {
        ClickHouseMapColumn(
            spec: .map(key: keySpec, value: valueSpec),
            keySpec: keySpec, valueSpec: valueSpec,
            offsets: offsets, keys: keys, values: values
        )
    }

    // MARK: - String-keyed maps

    @Test("Map(String, String) maps to .mapStringStringIndexed with rows sliced by offsets")
    func mapStringStringMapping() throws {
        // 2 rows: ["a":"1","b":"2"] and ["c":"3"]
        // Flat keys: ["a","b","c"], flat values: ["1","2","3"], offsets: [2, 3]
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .string,
            offsets: [2, 3],
            keys: ClickHouseStringColumn(values: ["a", "b", "c"]),
            values: ClickHouseStringColumn(values: ["1", "2", "3"])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "tags", internalColumn: column)
        guard case .mapStringStringIndexed(let storage) = publicColumn.values else {
            Issue.record("expected .mapStringStringIndexed case")
            return
        }
        #expect(storage.count == 2)
        #expect(storage.row(at: 0) == ["a": "1", "b": "2"])
        #expect(storage.row(at: 1) == ["c": "3"])
    }

    @Test("Map(String, Int32) maps to .mapStringInt32")
    func mapStringInt32Mapping() throws {
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .int32,
            offsets: [3, 4],
            keys: ClickHouseStringColumn(values: ["a", "b", "c", "d"]),
            values: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3, 4])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "counts", internalColumn: column)
        guard case .mapStringInt32(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringInt32 case")
            return
        }
        #expect(dicts == [["a": 1, "b": 2, "c": 3], ["d": 4]])
    }

    @Test("Map(String, Int64) maps to .mapStringInt64 preserving wide values")
    func mapStringInt64Mapping() throws {
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .int64,
            offsets: [2],
            keys: ClickHouseStringColumn(values: ["min", "max"]),
            values: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, Int64.max])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "limits", internalColumn: column)
        guard case .mapStringInt64(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringInt64 case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == ["min": Int64.min, "max": Int64.max])
    }

    @Test("Map(String, Float64) maps to .mapStringFloat64")
    func mapStringFloat64Mapping() throws {
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .float64,
            offsets: [2],
            keys: ClickHouseStringColumn(values: ["pi", "e"]),
            values: ClickHouseFloat64Column(values: [.pi, 2.71828])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "constants", internalColumn: column)
        guard case .mapStringFloat64(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringFloat64 case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0]["pi"] == .pi)
        #expect(dicts[0]["e"] == 2.71828)
    }

    @Test("Map(String, Bool) maps to .mapStringBool")
    func mapStringBoolMapping() throws {
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .bool,
            offsets: [2, 3],
            keys: ClickHouseStringColumn(values: ["enabled", "verified", "deleted"]),
            values: ClickHouseBoolColumn(values: [true, false, true])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "flags", internalColumn: column)
        guard case .mapStringBool(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringBool case")
            return
        }
        #expect(dicts.count == 2)
        #expect(dicts[0] == ["enabled": true, "verified": false])
        #expect(dicts[1] == ["deleted": true])
    }

    // MARK: - Integer-keyed maps

    @Test("Map(Int32, String) maps to .mapInt32String")
    func mapInt32StringMapping() throws {
        let column = Self.makeMap(
            keySpec: .int32, valueSpec: .string,
            offsets: [3],
            keys: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3]),
            values: ClickHouseStringColumn(values: ["one", "two", "three"])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "lookup", internalColumn: column)
        guard case .mapInt32String(let dicts) = publicColumn.values else {
            Issue.record("expected .mapInt32String case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == [1: "one", 2: "two", 3: "three"])
    }

    @Test("Map(Int64, String) maps to .mapInt64String")
    func mapInt64StringMapping() throws {
        let column = Self.makeMap(
            keySpec: .int64, valueSpec: .string,
            offsets: [2],
            keys: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, Int64.max]),
            values: ClickHouseStringColumn(values: ["min", "max"])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "lookup", internalColumn: column)
        guard case .mapInt64String(let dicts) = publicColumn.values else {
            Issue.record("expected .mapInt64String case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == [Int64.min: "min", Int64.max: "max"])
    }

    // MARK: - Edge cases

    @Test("an empty Map column produces an empty outer view")
    func emptyMapColumn() throws {
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .string,
            offsets: [],
            keys: ClickHouseStringColumn(values: []),
            values: ClickHouseStringColumn(values: [])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .mapStringStringIndexed(let storage) = publicColumn.values else {
            Issue.record("expected .mapStringStringIndexed case")
            return
        }
        #expect(storage.count == 0)
    }

    @Test("Map columns with all-empty inner rows preserve the row count")
    func mapColumnWithEmptyInnerRows() throws {
        // 3 rows, all empty maps — cumulative offsets stay at 0
        let column = Self.makeMap(
            keySpec: .string, valueSpec: .string,
            offsets: [0, 0, 0],
            keys: ClickHouseStringColumn(values: []),
            values: ClickHouseStringColumn(values: [])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .mapStringStringIndexed(let storage) = publicColumn.values else {
            Issue.record("expected .mapStringStringIndexed case")
            return
        }
        #expect(storage.count == 3)
        #expect(storage.row(at: 0) == [:])
        #expect(storage.row(at: 1) == [:])
        #expect(storage.row(at: 2) == [:])
    }

    // MARK: - Unsupported shapes

    @Test("Map(Int32, Int32) throws unsupportedSelectColumnType — no Values case for that combination")
    func mapIntIntThrowsUnsupported() throws {
        let column = Self.makeMap(
            keySpec: .int32, valueSpec: .int32,
            offsets: [1],
            keys: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1]),
            values: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [2])
        )
        #expect(throws: ClickHouseError.self) {
            try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        }
    }

    // MARK: - Wire round-trip

    @Test("Map(String, String) wire round-trips through encode/decode and the public mapper")
    func mapStringStringWireRoundTrip() throws {
        let original = Self.makeMap(
            keySpec: .string, valueSpec: .string,
            offsets: [2, 3, 5],
            keys: ClickHouseStringColumn(values: ["a", "b", "c", "d", "e"]),
            values: ClickHouseStringColumn(values: ["1", "2", "3", "4", "5"])
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .string, value: .string), rows: 3, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "m", internalColumn: decoded)

        guard case .mapStringStringIndexed(let storage) = publicColumn.values else {
            Issue.record("expected .mapStringStringIndexed case")
            return
        }
        #expect(storage.count == 3)
        #expect(storage.row(at: 0) == ["a": "1", "b": "2"])
        #expect(storage.row(at: 1) == ["c": "3"])
        #expect(storage.row(at: 2) == ["d": "4", "e": "5"])
        #expect(buffer.readableBytes == 0)
    }

    @Test("Map(Int32, String) wire round-trips with negative integer keys preserved")
    func mapInt32StringWireRoundTrip() throws {
        let original = Self.makeMap(
            keySpec: .int32, valueSpec: .string,
            offsets: [2],
            keys: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [-1, Int32.max]),
            values: ClickHouseStringColumn(values: ["neg-one", "max"])
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .int32, value: .string), rows: 1, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "m", internalColumn: decoded)

        guard case .mapInt32String(let dicts) = publicColumn.values else {
            Issue.record("expected .mapInt32String case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == [-1: "neg-one", Int32.max: "max"])
        #expect(buffer.readableBytes == 0)
    }

}
