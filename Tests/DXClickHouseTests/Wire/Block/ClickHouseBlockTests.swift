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

@Suite("ClickHouse block")
struct ClickHouseBlockTests {

    @Test("empty block (no columns, no rows) round-trips")
    func emptyBlockRoundTrip() throws {
        let block = ClickHouseBlock(blockInfo: .init(), columns: [])
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        #expect(decoded.columnCount == 0)
        #expect(decoded.rowCount == 0)
        #expect(buffer.readableBytes == 0)
    }

    @Test("single Int32 column block round-trips with the right values")
    func singleIntColumnRoundTrip() throws {
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20, 30])
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(name: "id", column: column)]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        #expect(decoded.columnCount == 1)
        #expect(decoded.rowCount == 3)
        #expect(decoded.columns[0].name == "id")
        let typed = try #require(decoded.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [10, 20, 30])
    }

    @Test("multi-column block with mixed types round-trips, including a composite")
    func multiColumnMixedTypesRoundTrip() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "id", column: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [1, 2])),
                .init(name: "name", column: ClickHouseStringColumn(values: ["alpha", "beta"])),
                .init(name: "tags", column: ClickHouseArrayColumn(
                    spec: .array(of: .string),
                    elementSpec: .string,
                    offsets: [2, 3],
                    inner: ClickHouseStringColumn(values: ["a", "b", "c"])
                )),
            ]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        #expect(decoded.columnCount == 3)
        #expect(decoded.rowCount == 2)

        let ids = try #require(decoded.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        let names = try #require(decoded.columns[1].column as? ClickHouseStringColumn)
        let tags = try #require(decoded.columns[2].column as? ClickHouseArrayColumn)
        #expect(ids.values == [1, 2])
        #expect(names.values == ["alpha", "beta"])
        #expect(tags.offsets == [2, 3])
        let tagInner = try #require(tags.inner as? ClickHouseStringColumn)
        #expect(tagInner.values == ["a", "b", "c"])
    }

    @Test("realistic OTel-style schema round-trips through the full pipeline")
    func realisticOtelSchema() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(isOverflows: false, bucketNumber: -1),
            columns: [
                .init(name: "trace_id", column: ClickHouseUUIDColumn(values: [UUID(), UUID()])),
                .init(name: "ts_ns", column: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .dateTime64(precision: 9, timezone: .explicit("UTC")), values: [1_700_000_000_000_000_000, 1_700_000_000_000_000_001])),
                .init(name: "labels", column: ClickHouseMapColumn(
                    spec: .map(key: .string, value: .string),
                    keySpec: .string,
                    valueSpec: .string,
                    offsets: [2, 4],
                    keys: ClickHouseStringColumn(values: ["k1", "k2", "k3", "k4"]),
                    values: ClickHouseStringColumn(values: ["v1", "v2", "v3", "v4"])
                )),
            ]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: 54_478)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        #expect(decoded.columns[0].name == "trace_id")
        #expect(decoded.columns[1].name == "ts_ns")
        #expect(decoded.columns[2].name == "labels")
        #expect(decoded.columns[1].column.spec == .dateTime64(precision: 9, timezone: .explicit("UTC")))
    }

    @Test("encode rejects a block whose columns have divergent row counts")
    func divergentRowCountsRejected() {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "a", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])),
                .init(name: "b", column: ClickHouseStringColumn(values: ["x", "y"])),
            ]
        )
        var buffer = ByteBuffer()
        #expect {
            try block.encode(into: &buffer, revision: 54_478)
        } throws: { error in
            guard case ClickHouseError.blockColumnRowCountMismatch(let index, let expected, let actual) = error else {
                return false
            }
            return index == 1 && expected == 3 && actual == 2
        }
    }

    @Test("legacy revision skips the custom-serialization byte and round-trips correctly")
    func legacyRevisionOmitsCustomSerialization() throws {
        let block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "id", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])),
            ]
        )
        var buffer = ByteBuffer()
        try block.encode(into: &buffer, revision: 54_400)

        let decoded = try ClickHouseBlock.decode(from: &buffer, revision: 54_400)
        let typed = try #require(decoded.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [1])
    }

    @Test("an absurd column count surfaces a typed error before allocating")
    func absurdColumnCountRejected() {
        var buffer = ByteBuffer()
        ClickHouseBlockInfo().encode(into: &buffer)
        buffer.writeClickHouseUVarInt(UInt64.max)
        buffer.writeClickHouseUVarInt(0)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        }
    }

    @Test("an absurd row count surfaces a typed error before allocating")
    func absurdRowCountRejected() {
        var buffer = ByteBuffer()
        ClickHouseBlockInfo().encode(into: &buffer)
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseUVarInt(UInt64.max)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        }
    }

    @Test("Block.decode rejects a column whose decoded rowCount disagrees with the block header")
    func columnRowCountDriftRejected() throws {
        // Forge a one-column block whose header claims rowCount=3 but
        // whose LowCardinality(String) wire payload encodes
        // indicesCount=2. Without the block-level row-count guard, the
        // decoder would happily produce a column with 2 rows in a block
        // that says it has 3, leaving callers iterating past the column's
        // backing array.
        var buffer = ByteBuffer()
        ClickHouseBlockInfo().encode(into: &buffer)
        buffer.writeClickHouseUVarInt(1)        // columnCount = 1
        buffer.writeClickHouseUVarInt(3)        // header rowCount = 3
        buffer.writeClickHouseString("col")     // column name
        buffer.writeClickHouseString("LowCardinality(String)")
        buffer.writeClickHouseBool(false)       // hasCustomSerialization

        // LowCardinality envelope (rows > 0 path):
        buffer.writeInteger(UInt64(1), endianness: .little)            // version
        let serializationType: UInt64 = 0 | (1 << 9)                   // keyType=0 + HasAdditionalKeys
        buffer.writeInteger(serializationType, endianness: .little)
        // dictionary: 1 entry "x"
        buffer.writeInteger(UInt64(1), endianness: .little)            // dictionarySize
        buffer.writeClickHouseString("x")
        // indicesCount = 2 (header says 3 → drift)
        buffer.writeInteger(UInt64(2), endianness: .little)
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeInteger(UInt8(0), endianness: .little)

        #expect(throws: ClickHouseError.self) {
            try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
        }
    }

}
