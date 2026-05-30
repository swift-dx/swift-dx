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

@Suite("ClickHouse Nothing, JSON, and missing Nullable variants")
struct ClickHouseNothingJSONNullableTests {

    // MARK: - Nothing

    @Test("Nothing typeName + parser round-trip")
    func nothingTypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.nothing.typeName == "Nothing")
        #expect(try ClickHouseTypeNameParser.parse("Nothing") == .nothing)
    }

    @Test("Nothing column has rowCount but consumes zero bytes from the buffer")
    func nothingConsumesZeroBytes() throws {
        var buffer = ByteBuffer()
        // No bytes written — Nothing has zero payload per row.
        let column = try ClickHouseColumnRegistry.decode(spec: .nothing, rows: 5, from: &buffer)
        let typed = try #require(column as? ClickHouseNothingColumn)
        #expect(typed.rowCount == 5)
        #expect(buffer.readableBytes == 0)
    }

    @Test("Nothing column encode produces zero output bytes")
    func nothingEncodeProducesZeroBytes() {
        let column = ClickHouseNothingColumn(spec: .nothing, rowCount: 100)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)
    }

    @Test("Nothing column with zero rows is valid")
    func nothingZeroRows() throws {
        var buffer = ByteBuffer()
        let column = try ClickHouseColumnRegistry.decode(spec: .nothing, rows: 0, from: &buffer)
        let typed = try #require(column as? ClickHouseNothingColumn)
        #expect(typed.rowCount == 0)
    }

    // MARK: - JSON

    @Test("JSON typeName + parser round-trip")
    func jsonTypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.json.typeName == "JSON")
        #expect(try ClickHouseTypeNameParser.parse("JSON") == .json)
    }

    @Test("JSON column round-trips raw JSON strings via the registry (wire format identical to String)")
    func jsonStringRoundTrip() throws {
        let original: [String] = [
            "{}",
            "{\"x\":1}",
            "{\"name\":\"alice\",\"tags\":[\"a\",\"b\"]}",
            "[1, 2, 3]",
            "null",
            "\"plain string\""
        ]
        let column = ClickHouseStringColumn(values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .json, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseStringColumn)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("public typed-INSERT API converts .json to a ClickHouseStringColumn")
    func publicAPIConvertsJSON() throws {
        let original = ["{\"a\":1}", "{\"b\":2}"]
        let column = try ClickHouseClient.toInternalColumn(.json(original))
        let typed = try #require(column as? ClickHouseStringColumn)
        #expect(typed.values == original)
    }

    // MARK: - Nullable variants

    @Test("nullableInt8 round-trips with nil and present values")
    func nullableInt8RoundTrip() throws {
        let original: [Int8?] = [nil, 0, 1, -1, Int8.min, Int8.max, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableInt8(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == original.count)
        #expect(typed.spec == .nullable(of: .int8))
    }

    @Test("nullableInt16 round-trips with nil and present values")
    func nullableInt16RoundTrip() throws {
        let original: [Int16?] = [nil, 100, -100, Int16.min, Int16.max, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableInt16(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == original.count)
        #expect(typed.spec == .nullable(of: .int16))
    }

    @Test("nullableUInt8 round-trips")
    func nullableUInt8RoundTrip() throws {
        let original: [UInt8?] = [nil, 0, 255, 42]
        let column = try ClickHouseClient.toInternalColumn(.nullableUInt8(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .uint8))
    }

    @Test("nullableUInt16 round-trips")
    func nullableUInt16RoundTrip() throws {
        let original: [UInt16?] = [nil, 0, UInt16.max, 1024]
        let column = try ClickHouseClient.toInternalColumn(.nullableUInt16(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .uint16))
    }

    @Test("nullableFloat32 round-trips with NaN and infinity preserved")
    func nullableFloat32RoundTrip() throws {
        let original: [Float32?] = [nil, 0.0, 1.5, -1.5, .infinity, -.infinity, .nan, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableFloat32(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .float32))
        #expect(typed.rowCount == original.count)
    }

    @Test("a nullable column with all nil entries still tracks the correct rowCount")
    func nullableAllNilTracksRowCount() throws {
        let original: [Int8?] = [nil, nil, nil, nil, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableInt8(original.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == 5)
    }

    @Test("an empty nullable column produces a 0-row column")
    func emptyNullableColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.nullableInt16([]))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == 0)
    }

}
