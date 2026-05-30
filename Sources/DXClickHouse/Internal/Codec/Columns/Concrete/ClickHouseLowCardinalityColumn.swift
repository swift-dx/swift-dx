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

import NIOCore

// CH `LowCardinality(T)` wire layout (only emitted when rowCount > 0):
//   UInt64    serialization version (always 1)
//   UInt64    serialization type — low byte = key width
//                (0=UInt8, 1=UInt16, 2=UInt32, 3=UInt64), bit 9 set =
//                HasAdditionalKeys (we always set this; we send our
//                own dictionary inline)
//   UInt64    dictionary size
//   ...       dictionary values (encoded as the inner column type)
//   UInt64    indices count (= rowCount)
//   ...       indices (width per key type)
//
// When rowCount == 0, no bytes are emitted at all — the entire
// envelope is omitted and the next packet follows immediately.
struct ClickHouseLowCardinalityColumn: ClickHouseColumn {

    static let serializationVersion: UInt64 = 1
    static let hasAdditionalKeysFlag: UInt64 = 1 << 9

    let spec: ClickHouseColumnSpec
    let innerSpec: ClickHouseColumnSpec
    var dictionary: any ClickHouseColumn
    var indices: [UInt64]

    var rowCount: Int { indices.count }

    func encodePrefix(into buffer: inout ByteBuffer) throws {
        // The KeysSerializationVersion must precede the body bytes
        // at the chunk start so CH's NativeReader can parse it before
        // recursing into composites (offsets, tuple element order,
        // etc.). CH writes this even when the underlying data is
        // empty — e.g., a Map(LC, V) with all empty maps still emits
        // the inner LC prefix at the column-chunk start — so the
        // SDK must too. Skipping it on empty inner columns would
        // leave 8 missing bytes that the server reads from the next
        // substream's offsets and rejects as "Invalid version".
        buffer.writeInteger(Self.serializationVersion, endianness: .little)
    }

    func encode(into buffer: inout ByteBuffer) throws {
        guard !indices.isEmpty else { return }

        let dictionarySize = dictionary.rowCount
        let keyType = Self.keyType(forDictionarySize: dictionarySize)
        let serializationType = UInt64(keyType) | Self.hasAdditionalKeysFlag
        buffer.writeInteger(serializationType, endianness: .little)

        buffer.writeInteger(UInt64(dictionarySize), endianness: .little)
        try dictionary.encode(into: &buffer)

        buffer.writeInteger(UInt64(indices.count), endianness: .little)
        // Bulk path: narrow the [UInt64] to the keyType's width once,
        // then hand to the fixed-width-integer bulk writer (which is
        // a single bulk-copy on little-endian hosts). Replaces N
        // writeInteger calls with one allocation + one writeBytes per
        // column. The narrowing casts trap on overflow, matching the
        // per-row trap behavior of the previous loop — a malformed
        // column with index >= keyType max would surface immediately
        // rather than silently truncate.
        switch keyType {
        case 0:
            buffer.writeClickHouseFixedWidthIntegers(indices.map { UInt8($0) })
        case 1:
            buffer.writeClickHouseFixedWidthIntegers(indices.map { UInt16($0) })
        case 2:
            buffer.writeClickHouseFixedWidthIntegers(indices.map { UInt32($0) })
        default:
            buffer.writeClickHouseFixedWidthIntegers(indices)
        }
    }

    // Reads the chunk-level prefix — the KeysSerializationVersion that
    // CH writes once per LowCardinality substream before any body
    // bytes (offsets, dictionary, indices). Called only from
    // `Block.decode` when the block has rows; CH omits the prefix
    // entirely for zero-row blocks (which only carry schema), so the
    // caller's `rowCount > 0` gate is the precondition. Always reads
    // when called — if the bytes are missing it's a truncated wire
    // chunk and `truncatedBuffer` is the right diagnosis.
    static func decodePrefix(from buffer: inout ByteBuffer) throws {
        _ = try buffer.readClickHouseFixedWidthInteger(UInt64.self)
    }

    static func decode(innerSpec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        if rows == 0 {
            return try decodeEmpty(innerSpec: innerSpec, from: &buffer)
        }
        let keyType = try readAndValidateKeyType(from: &buffer)
        let dictionary = try readDictionary(innerSpec: innerSpec, from: &buffer)
        let indices = try readIndices(rows: rows, keyType: keyType, from: &buffer)
        return .init(
            spec: .lowCardinality(of: innerSpec),
            innerSpec: innerSpec,
            dictionary: dictionary,
            indices: indices
        )
    }

    private static func decodeEmpty(innerSpec: ClickHouseColumnSpec, from buffer: inout ByteBuffer) throws -> Self {
        .init(
            spec: .lowCardinality(of: innerSpec),
            innerSpec: innerSpec,
            dictionary: try ClickHouseColumnRegistry.decode(spec: innerSpec, rows: 0, from: &buffer),
            indices: []
        )
    }

    private static func readAndValidateKeyType(from buffer: inout ByteBuffer) throws -> UInt8 {
        let serializationType = try buffer.readClickHouseFixedWidthInteger(UInt64.self)
        let keyType = UInt8(serializationType & 0xFF)
        guard keyType <= 3 else {
            throw ClickHouseError.lowCardinalityInvalidKeyType(rawValue: keyType)
        }
        return keyType
    }

    private static func readDictionary(innerSpec: ClickHouseColumnSpec, from buffer: inout ByteBuffer) throws -> any ClickHouseColumn {
        let dictionarySize = try buffer.readClickHouseFixedWidthInteger(UInt64.self)
        guard let dictionarySizeInt = Int(exactly: dictionarySize) else {
            throw ClickHouseError.blockColumnCountExceedsInt(dictionarySize)
        }
        return try ClickHouseColumnRegistry.decode(spec: innerSpec, rows: dictionarySizeInt, from: &buffer)
    }

    private static func readIndices(rows: Int, keyType: UInt8, from buffer: inout ByteBuffer) throws -> [UInt64] {
        let indicesCount = try buffer.readClickHouseFixedWidthInteger(UInt64.self)
        let indicesCountInt = try requireIndicesCount(rows: rows, indicesCount: indicesCount)
        return try readIndicesByKeyType(keyType: keyType, indicesCount: indicesCountInt, from: &buffer)
    }

    private static func requireIndicesCount(rows: Int, indicesCount: UInt64) throws -> Int {
        guard let indicesCountInt = Int(exactly: indicesCount) else {
            throw ClickHouseError.blockRowCountExceedsInt(indicesCount)
        }
        guard indicesCountInt == rows else {
            throw ClickHouseError.blockColumnRowCountMismatch(
                columnIndex: -1,
                expected: rows,
                actual: indicesCountInt
            )
        }
        return indicesCountInt
    }

    private static func readIndicesByKeyType(keyType: UInt8, indicesCount: Int, from buffer: inout ByteBuffer) throws -> [UInt64] {
        switch keyType {
        case 0: return try readIndicesWidening(UInt8.self, indicesCount: indicesCount, from: &buffer)
        case 1: return try readIndicesWidening(UInt16.self, indicesCount: indicesCount, from: &buffer)
        case 2: return try readIndicesWidening(UInt32.self, indicesCount: indicesCount, from: &buffer)
        default: return try buffer.readClickHouseFixedWidthIntegers(UInt64.self, rows: indicesCount)
        }
    }

    // Single-shot read + widen. Avoids the `.map { UInt64($0) }`
    // pattern that allocates an intermediate Array<T> and then
    // an Array<UInt64>, copying twice. The `unsafeUninitializedCapacity`
    // path writes directly into the destination buffer through a
    // raw pointer, skipping CoW uniqueness checks per element.
    private static func readIndicesWidening<T: FixedWidthInteger & UnsignedInteger>(
        _ type: T.Type,
        indicesCount: Int,
        from buffer: inout ByteBuffer
    ) throws -> [UInt64] {
        let narrow = try buffer.readClickHouseFixedWidthIntegers(T.self, rows: indicesCount)
        return [UInt64](unsafeUninitializedCapacity: indicesCount) { resultBuffer, resultCount in
            guard let resultPointer = resultBuffer.baseAddress else {
                resultCount = 0
                return
            }
            narrow.withUnsafeBufferPointer { narrowBuffer in
                guard let narrowPointer = narrowBuffer.baseAddress else { return }
                for index in 0..<indicesCount {
                    resultPointer[index] = UInt64(narrowPointer[index])
                }
            }
            resultCount = indicesCount
        }
    }

    private static func keyType(forDictionarySize size: Int) -> UInt8 {
        if size <= Int(UInt8.max) { return 0 }
        return keyTypeWide(forDictionarySize: size)
    }

    private static func keyTypeWide(forDictionarySize size: Int) -> UInt8 {
        if size <= Int(UInt16.max) { return 1 }
        if size <= Int(UInt32.max) { return 2 }
        return 3
    }

}
