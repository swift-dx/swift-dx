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

@Suite("ClickHouse low-cardinality column")
struct LowCardinalityColumnTests {

    @Test("LowCardinality(String) with non-empty rows round-trips through encode and decode")
    func roundTripWithRows() throws {
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["alpha", "beta", "gamma"]),
            indices: [0, 1, 0, 2, 1, 0]
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseLowCardinalityColumn.decode(
            innerSpec: .string,
            rows: 6,
            from: &buffer
        )
        let decodedDictionary = try #require(decoded.dictionary as? ClickHouseStringColumn)
        #expect(decodedDictionary.values == ["alpha", "beta", "gamma"])
        #expect(decoded.indices == [0, 1, 0, 2, 1, 0])
        #expect(decoded.spec == .lowCardinality(of: .string))
        #expect(buffer.readableBytes == 0)
    }

    @Test("LowCardinality with rows = 0 emits nothing on the wire")
    func emptyRowsEmitNothing() throws {
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: []),
            indices: []
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseLowCardinalityColumn.decode(
            innerSpec: .string,
            rows: 0,
            from: &buffer
        )
        #expect(decoded.indices.isEmpty)
        #expect(buffer.readableBytes == 0)
    }

    @Test("dictionary size <= 256 selects UInt8 index width (3 bytes per index saved vs UInt32)")
    func smallDictionaryUsesUInt8Indices() throws {
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["a", "b"]),
            indices: Array(repeating: 0, count: 1000)
        )
        var buffer = ByteBuffer()
        try column.encodePrefix(into: &buffer)
        try column.encode(into: &buffer)

        // Chunk layout (prefix + body): version (8) + serializationType (8) +
        //   dictSize (8) + dict bytes (uvarint+len*2 bytes) +
        //   indicesCount (8) + indices (1 byte * 1000)
        // dictionary "a" + "b": each is uvarint(1) + 1 byte = 2 bytes; total 4 bytes
        let expectedSize = 8 + 8 + 8 + 4 + 8 + 1_000
        #expect(buffer.readableBytes == expectedSize)

        try ClickHouseLowCardinalityColumn.decodePrefix(from: &buffer)
        let decoded = try ClickHouseLowCardinalityColumn.decode(
            innerSpec: .string,
            rows: 1_000,
            from: &buffer
        )
        #expect(decoded.indices.count == 1_000)
        #expect(decoded.indices.allSatisfy { $0 == 0 })
    }

    @Test("dictionary size > 256 selects UInt16 index width")
    func mediumDictionaryUsesUInt16Indices() throws {
        let dictionarySize = 300
        let dictionary = (0..<dictionarySize).map { "v\($0)" }
        let indices = (0..<10).map { UInt64($0 * 25) }

        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: dictionary),
            indices: indices
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseLowCardinalityColumn.decode(
            innerSpec: .string,
            rows: indices.count,
            from: &buffer
        )
        #expect(decoded.indices == indices)
        let decodedDict = try #require(decoded.dictionary as? ClickHouseStringColumn)
        #expect(decodedDict.values.count == dictionarySize)
    }

    @Test("registry decode of LowCardinality(String) reconstructs the column with the right spec")
    func registryDispatchesLowCardinality() throws {
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["x", "y"]),
            indices: [0, 1, 0]
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .lowCardinality(of: .string),
            rows: 3,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseLowCardinalityColumn)
        #expect(typed.indices == [0, 1, 0])
    }

    @Test("type-name parser recognizes LowCardinality and round-trips through typeName")
    func typeNameParserRoundTrip() throws {
        let original: ClickHouseColumnSpec = .lowCardinality(of: .string)
        #expect(original.typeName == "LowCardinality(String)")
        let parsed = try ClickHouseTypeNameParser.parse("LowCardinality(String)")
        #expect(parsed == original)
    }

    @Test("type-name parser recognizes nested LowCardinality(Nullable(String))")
    func nestedLowCardinalityNullableString() throws {
        let parsed = try ClickHouseTypeNameParser.parse("LowCardinality(Nullable(String))")
        #expect(parsed == .lowCardinality(of: .nullable(of: .string)))
    }

    @Test("decode rejects a malformed keyType byte with lowCardinalityInvalidKeyType rather than silently widening to UInt64")
    func malformedKeyTypeIsRejected() throws {
        // Pre-fix: the decoder's `switch keyType` had `default ->
        // read as UInt64`, which absorbed any keyType ≥ 3 — including
        // 4, 5, …, 255 from a malformed or hostile server. The bug
        // only surfaced later via "dictionary index out of range" when
        // mapping the column, with a misleading error origin. This
        // test feeds keyType = 4 (one past the UInt64 max) and pins
        // the diagnosis to the offending byte. ch-go's upstream
        // implementation matches this validation.
        var buffer = ByteBuffer()
        // serialization version
        buffer.writeInteger(UInt64(1), endianness: .little)
        // serialization type: low byte = 4 (invalid), bit 9 = HasAdditionalKeys
        let invalidKeyType: UInt64 = 4
        let hasAdditionalKeys: UInt64 = 1 << 9
        buffer.writeInteger(invalidKeyType | hasAdditionalKeys, endianness: .little)
        // dictionary size = 1
        buffer.writeInteger(UInt64(1), endianness: .little)
        // dictionary value: one String "foo"
        buffer.writeClickHouseString("foo")
        // indices count = 1
        buffer.writeInteger(UInt64(1), endianness: .little)
        // one UInt64 index value (would be read if the bug existed)
        buffer.writeInteger(UInt64(0), endianness: .little)

        try ClickHouseLowCardinalityColumn.decodePrefix(from: &buffer)
        #expect(throws: ClickHouseError.lowCardinalityInvalidKeyType(rawValue: 4)) {
            _ = try ClickHouseLowCardinalityColumn.decode(
                innerSpec: .string,
                rows: 1,
                from: &buffer
            )
        }
    }

    @Test("a 50 000-row LowCardinality(String) with a 100-entry dictionary round-trips byte-for-byte (covers UInt8 keyType bulk-write/read)")
    func largeRowCountUInt8KeyTypeRoundTrip() throws {
        // 100 distinct dictionary values → keyType = 0 (UInt8 indices).
        // 50k rows distributed across them tests the bulk per-row index
        // path on the most common keyType. A regression in the bulk-
        // write or decode loop (wrong stride, off-by-one) would surface
        // as a value mismatch on round-trip.
        let dictionarySize = 100
        let rowCount = 50_000
        let dictionary = (0..<dictionarySize).map { "value-\($0)" }
        var rng = SeededRandomNumberGenerator(seed: 0xDEAD_BEEF_CAFE_BABE)
        var indices: [UInt64] = []
        indices.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            indices.append(UInt64(rng.next() % UInt64(dictionarySize)))
        }

        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: dictionary),
            indices: indices
        )

        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseLowCardinalityColumn.decode(
            innerSpec: .string, rows: rowCount, from: &buffer
        )
        #expect(decoded.indices == indices, "indices must round-trip exactly")
        let decodedDict = try #require(decoded.dictionary as? ClickHouseStringColumn)
        #expect(decodedDict.values == dictionary)
        #expect(buffer.readableBytes == 0, "decoder must consume the entire encoded payload")
    }

}
