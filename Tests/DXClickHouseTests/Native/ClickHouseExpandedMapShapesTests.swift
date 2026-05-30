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

@Suite("ClickHouse Map(K, V) — expanded shapes (Float32/UUID/DateTime/UInt64-Int64)")
struct ClickHouseExpandedMapShapesTests {

    // MARK: - INSERT side: toInternalColumn

    @Test("Map(String, Float32) INSERT builds a ClickHouseMapColumn with the expected key/value specs")
    func insertMapStringFloat32() throws {
        let dicts: [[String: Float32]] = [["a": 0.5, "b": -1.0], ["c": 2.5]]
        let column = try ClickHouseClient.toInternalColumn(.mapStringFloat32(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .string, value: .float32))
        #expect(typed.rowCount == 2)
        let valueColumn = try #require(typed.values as? ClickHouseFloat32Column)
        // Order within a dictionary isn't guaranteed but the count should be exact
        #expect(valueColumn.values.count == 3)
    }

    @Test("Map(String, UUID) INSERT builds a ClickHouseMapColumn with String keys and UUID values")
    func insertMapStringUUID() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let dicts: [[String: UUID]] = [["primary": id]]
        let column = try ClickHouseClient.toInternalColumn(.mapStringUUID(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .string, value: .uuid))
        let valueColumn = try #require(typed.values as? ClickHouseUUIDColumn)
        #expect(valueColumn.values == [id])
    }

    @Test("Map(String, DateTime) INSERT converts each Date value to UInt32 seconds-since-epoch")
    func insertMapStringDateTime() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dicts: [[String: Date]] = [["created": date]]
        let column = try ClickHouseClient.toInternalColumn(.mapStringDateTime(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .string, value: .dateTime(timezone: .serverDefault)))
        let valueColumn = try #require(typed.values as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(valueColumn.values == [1_700_000_000])
    }

    @Test("Map(UInt64, Int64) INSERT builds a ClickHouseMapColumn with integer keys and values")
    func insertMapUInt64Int64() throws {
        let dicts: [[UInt64: Int64]] = [[1: 100, 2: 200]]
        let column = try ClickHouseClient.toInternalColumn(.mapUInt64Int64(dicts))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.spec == .map(key: .uint64, value: .int64))
        #expect(typed.rowCount == 1)
        let keyColumn = try #require(typed.keys as? ClickHouseFixedWidthIntegerColumn<UInt64>)
        let valueColumn = try #require(typed.values as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(keyColumn.values.count == 2)
        #expect(valueColumn.values.count == 2)
    }

    @Test("an empty Map column INSERT produces a column with rowCount 0 and no inner entries")
    func insertEmptyMapColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.mapStringFloat32([]))
        let typed = try #require(column as? ClickHouseMapColumn)
        #expect(typed.rowCount == 0)
        let valueColumn = try #require(typed.values as? ClickHouseFloat32Column)
        #expect(valueColumn.values.isEmpty)
    }

    // MARK: - SELECT side: column→Values mapping

    @Test("SELECT Map(String, Float32) maps to .mapStringFloat32 with rows sliced by offsets")
    func selectMapStringFloat32() throws {
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .float32),
            keySpec: .string, valueSpec: .float32,
            offsets: [2, 3],
            keys: ClickHouseStringColumn(values: ["a", "b", "c"]),
            values: ClickHouseFloat32Column(values: [0.5, -1.0, 2.5])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "weights", internalColumn: column)
        guard case .mapStringFloat32(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringFloat32 case")
            return
        }
        #expect(dicts == [["a": 0.5, "b": -1.0], ["c": 2.5]])
    }

    @Test("SELECT Map(String, UUID) maps to .mapStringUUID")
    func selectMapStringUUID() throws {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .uuid),
            keySpec: .string, valueSpec: .uuid,
            offsets: [2],
            keys: ClickHouseStringColumn(values: ["primary", "secondary"]),
            values: ClickHouseUUIDColumn(values: [id1, id2])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "refs", internalColumn: column)
        guard case .mapStringUUID(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringUUID case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == ["primary": id1, "secondary": id2])
    }

    @Test("SELECT Map(String, DateTime) converts UInt32 seconds back to Date values")
    func selectMapStringDateTime() throws {
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .dateTime(timezone: .serverDefault)),
            keySpec: .string, valueSpec: .dateTime(timezone: .serverDefault),
            offsets: [2],
            keys: ClickHouseStringColumn(values: ["created", "modified"]),
            values: ClickHouseFixedWidthIntegerColumn<UInt32>(
                spec: .dateTime(timezone: .serverDefault),
                values: [1_700_000_000, 1_700_000_001]
            )
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ts", internalColumn: column)
        guard case .mapStringDateTime(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringDateTime case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0]["created"] == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(dicts[0]["modified"] == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test("SELECT Map(UInt64, Int64) maps to .mapUInt64Int64 with both as native integers")
    func selectMapUInt64Int64() throws {
        let column = ClickHouseMapColumn(
            spec: .map(key: .uint64, value: .int64),
            keySpec: .uint64, valueSpec: .int64,
            offsets: [3],
            keys: ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [1, 2, 3]),
            values: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [Int64.min, 0, Int64.max])
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "counts", internalColumn: column)
        guard case .mapUInt64Int64(let dicts) = publicColumn.values else {
            Issue.record("expected .mapUInt64Int64 case")
            return
        }
        #expect(dicts.count == 1)
        #expect(dicts[0] == [1: Int64.min, 2: 0, 3: Int64.max])
    }

    // MARK: - End-to-end wire round-trip

    @Test("Map(String, Float32) round-trips through encode/decode preserving every key+value")
    func wireRoundTripMapStringFloat32() throws {
        let original: [[String: Float32]] = [["pi": 3.14, "e": 2.71], ["zero": 0.0]]
        let column = try ClickHouseClient.toInternalColumn(.mapStringFloat32(original))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .string, value: .float32),
            rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "m", internalColumn: decoded)
        guard case .mapStringFloat32(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringFloat32 case")
            return
        }
        #expect(dicts.count == 2)
        #expect(dicts[0] == ["pi": 3.14, "e": 2.71])
        #expect(dicts[1] == ["zero": 0.0])
        #expect(buffer.readableBytes == 0, "every wire byte consumed")
    }

    @Test("Map(UInt64, Int64) round-trips through encode/decode preserving boundary values")
    func wireRoundTripMapUInt64Int64() throws {
        let original: [[UInt64: Int64]] = [[100: -1, 200: 0], [UInt64.max: Int64.max]]
        let column = try ClickHouseClient.toInternalColumn(.mapUInt64Int64(original))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .uint64, value: .int64),
            rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "m", internalColumn: decoded)
        guard case .mapUInt64Int64(let dicts) = publicColumn.values else {
            Issue.record("expected .mapUInt64Int64 case")
            return
        }
        #expect(dicts.count == 2)
        #expect(dicts[0] == [100: -1, 200: 0])
        #expect(dicts[1] == [UInt64.max: Int64.max])
        #expect(buffer.readableBytes == 0)
    }

    @Test("Map(String, UUID) round-trips through encode/decode preserving every UUID value")
    func wireRoundTripMapStringUUID() throws {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let original: [[String: UUID]] = [["min": id1, "max": id2]]
        let column = try ClickHouseClient.toInternalColumn(.mapStringUUID(original))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .string, value: .uuid),
            rows: 1, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "m", internalColumn: decoded)
        guard case .mapStringUUID(let dicts) = publicColumn.values else {
            Issue.record("expected .mapStringUUID case")
            return
        }
        #expect(dicts == [["min": id1, "max": id2]])
        #expect(buffer.readableBytes == 0)
    }

}
