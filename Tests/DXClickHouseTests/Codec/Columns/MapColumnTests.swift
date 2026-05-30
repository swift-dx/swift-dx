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

@Suite("ClickHouse map column")
struct MapColumnTests {

    @Test("Map(String, Int32) round-trips with mixed-size and empty rows")
    func mapStringToInt32() throws {
        let keys = ClickHouseStringColumn(values: ["a", "b", "c", "d", "e"])
        let values = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3, 4, 5])
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int32),
            keySpec: .string,
            valueSpec: .int32,
            offsets: [2, 2, 5],
            keys: keys,
            values: values
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseMapColumn.decode(
            keySpec: .string,
            valueSpec: .int32,
            rows: 3,
            from: &buffer
        )
        #expect(decoded.offsets == [2, 2, 5])
        let decodedKeys = try #require(decoded.keys as? ClickHouseStringColumn)
        let decodedValues = try #require(decoded.values as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(decodedKeys.values == ["a", "b", "c", "d", "e"])
        #expect(decodedValues.values == [1, 2, 3, 4, 5])
        #expect(buffer.readableBytes == 0)
    }

    @Test("zero-row Map consumes zero bytes")
    func zeroRowMap() throws {
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int32),
            keySpec: .string,
            valueSpec: .int32,
            offsets: [],
            keys: ClickHouseStringColumn(values: []),
            values: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseMapColumn.decode(keySpec: .string, valueSpec: .int32, rows: 0, from: &buffer)
        #expect(decoded.rowCount == 0)
    }

    @Test("Map shares the wire format of Array(Tuple(K, V))")
    func wireFormatMatchesArrayOfTuples() throws {
        let mapColumn = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int64),
            keySpec: .string,
            valueSpec: .int64,
            offsets: [1, 3],
            keys: ClickHouseStringColumn(values: ["x", "y", "z"]),
            values: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [10, 20, 30])
        )

        let arrayOfTupleColumn = ClickHouseArrayColumn(
            spec: .array(of: .tuple(elements: [.string, .int64])),
            elementSpec: .tuple(elements: [.string, .int64]),
            offsets: [1, 3],
            inner: ClickHouseTupleColumn(
                spec: .tuple(elements: [.string, .int64]),
                elementSpecs: [.string, .int64],
                elements: [
                    ClickHouseStringColumn(values: ["x", "y", "z"]),
                    ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [10, 20, 30]),
                ],
                rowCount: 3
            )
        )

        var mapBuffer = ByteBuffer()
        try mapColumn.encode(into: &mapBuffer)
        var arrayBuffer = ByteBuffer()
        try arrayOfTupleColumn.encode(into: &arrayBuffer)

        let mapBytes = mapBuffer.getBytes(at: mapBuffer.readerIndex, length: mapBuffer.readableBytes) ?? []
        let arrayBytes = arrayBuffer.getBytes(at: arrayBuffer.readerIndex, length: arrayBuffer.readableBytes) ?? []
        #expect(mapBytes == arrayBytes)
    }

    @Test("non-monotonic Map offsets are rejected")
    func nonMonotonicMapOffsetsRejected() {
        var buffer = ByteBuffer()
        buffer.writeClickHouseFixedWidthIntegers([UInt64(3), UInt64(1)])

        #expect(throws: ClickHouseError.self) {
            try ClickHouseMapColumn.decode(keySpec: .string, valueSpec: .int32, rows: 2, from: &buffer)
        }
    }

    @Test("registry decode of Map preserves both spec halves")
    func registryDispatchPreservesSpec() throws {
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int32),
            keySpec: .string,
            valueSpec: .int32,
            offsets: [1],
            keys: ClickHouseStringColumn(values: ["k"]),
            values: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42])
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .map(key: .string, value: .int32),
            rows: 1,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseMapColumn)
        #expect(typed.keySpec == .string)
        #expect(typed.valueSpec == .int32)
    }

    @Test("encode rejects a Map column whose keys row count disagrees with the last offset, instead of silently writing corrupt bytes")
    func encodeRejectsKeysOffsetMismatch() {
        // Offsets claim 4 elements; keys has 4 (matching), values has
        // only 2. Pre-fix the encoder would silently write keys (4
        // strings) followed by values (2 ints), leaving the wire short
        // by 2 ints — which the next column would then misframe.
        let column = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int32),
            keySpec: .string,
            valueSpec: .int32,
            offsets: [4],
            keys: ClickHouseStringColumn(values: ["a", "b", "c", "d"]),
            values: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2])
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
            received == .nullableInnerRowCountMismatch(expected: 4, actual: 2),
            "encoder must reject offset/values mismatch with a typed error, got \(String(describing: thrown))"
        )
    }

}
