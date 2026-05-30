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

// The unit of data flow in CH's wire protocol. Every Data, Totals,
// Extremes, Log, and ProfileEvents packet body IS a Block.
//
// Wire layout:
//   BlockInfo
//   UVarInt   columnCount
//   UVarInt   rowCount
//   for each column:
//     String  columnName
//     String  typeName  (parsed via ClickHouseTypeNameParser)
//     if revision >= 54454: Bool hasCustomSerialization
//       if hasCustomSerialization:
//         UInt8 serializationKind   (0=default, 1=sparse)
//     column bytes (decoded via ClickHouseColumnRegistry, or via
//     ClickHouseSparseColumnDecoder when kind == sparse)
//
// On encode we always send hasCustomSerialization == false: the SDK
// emits the column in its default codec, and the server accepts that
// regardless of any sparse hint it might have offered.
struct ClickHouseBlock: Sendable {

    static let revisionWithCustomSerialization: UInt64 = 54_454

    var blockInfo: ClickHouseBlockInfo
    var columns: [NamedColumn]

    var columnCount: Int { columns.count }
    var rowCount: Int { columns.first?.column.rowCount ?? 0 }

    func encode(into buffer: inout ByteBuffer, revision: UInt64) throws {
        try assertConsistentRowCounts()
        blockInfo.encode(into: &buffer)
        buffer.writeClickHouseUVarInt(UInt64(columnCount))
        buffer.writeClickHouseUVarInt(UInt64(rowCount))
        for namedColumn in columns {
            buffer.writeClickHouseString(namedColumn.name)
            buffer.writeClickHouseString(namedColumn.column.spec.typeName)
            if revision >= Self.revisionWithCustomSerialization {
                buffer.writeClickHouseBool(false)
            }
            // CH's NativeReader runs two passes per column on INSERT:
            // `deserializeBinaryBulkStatePrefix` then
            // `deserializeBinaryBulkWithMultipleStreams`. Mirror that
            // order so a LowCardinality column anywhere in a nested
            // composite (Map(LC, V), Array(LC), Tuple(..., LC, ...))
            // has its KeysSerializationVersion at the chunk start —
            // before the composite's offsets/null mask — instead of
            // buried inside the body bytes.
            try namedColumn.column.encodePrefix(into: &buffer)
            try namedColumn.column.encode(into: &buffer)
        }
    }

    static func decode(from buffer: inout ByteBuffer, revision: UInt64) throws -> Self {
        let blockInfo = try ClickHouseBlockInfo.decode(from: &buffer)
        let header = try decodeBlockHeader(from: &buffer)
        var columns: [NamedColumn] = []
        columns.reserveCapacity(min(header.columnCount, buffer.readableBytes))
        for columnIndex in 0..<header.columnCount {
            columns.append(try decodeNamedColumn(columnIndex: columnIndex, rowCount: header.rowCount, revision: revision, from: &buffer))
        }
        return .init(blockInfo: blockInfo, columns: columns)
    }

    private struct BlockHeader {
        let columnCount: Int
        let rowCount: Int
    }

    private static func decodeBlockHeader(from buffer: inout ByteBuffer) throws -> BlockHeader {
        let columnCountRaw = try buffer.readClickHouseUVarInt()
        let rowCountRaw = try buffer.readClickHouseUVarInt()
        guard let columnCount = Int(exactly: columnCountRaw) else {
            throw ClickHouseError.blockColumnCountExceedsInt(columnCountRaw)
        }
        guard let rowCount = Int(exactly: rowCountRaw) else {
            throw ClickHouseError.blockRowCountExceedsInt(rowCountRaw)
        }
        return BlockHeader(columnCount: columnCount, rowCount: rowCount)
    }

    private static func decodeNamedColumn(columnIndex: Int, rowCount: Int, revision: UInt64, from buffer: inout ByteBuffer) throws -> NamedColumn {
        let name = try buffer.readClickHouseString()
        let typeNameString = try buffer.readClickHouseString()
        let kind = try Self.readSerializationKind(revision: revision, from: &buffer)
        let spec = try ClickHouseTypeNameParser.parse(typeNameString)
        try decodePrefixIfNeeded(spec: spec, kind: kind, rowCount: rowCount, from: &buffer)
        let column = try Self.decodeColumn(spec: spec, rows: rowCount, kind: kind, from: &buffer)
        try requireColumnRowCount(columnIndex: columnIndex, expected: rowCount, actual: column.rowCount)
        return .init(name: name, column: column)
    }

    private static func decodePrefixIfNeeded(spec: ClickHouseColumnSpec, kind: ClickHouseSerializationKind, rowCount: Int, from buffer: inout ByteBuffer) throws {
        guard kind == .default, rowCount > 0 else { return }
        try ClickHouseColumnRegistry.decodePrefix(spec: spec, from: &buffer)
    }

    private static func requireColumnRowCount(columnIndex: Int, expected: Int, actual: Int) throws {
        guard actual == expected else {
            throw ClickHouseError.blockColumnRowCountMismatch(
                columnIndex: columnIndex,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func readSerializationKind(
        revision: UInt64,
        from buffer: inout ByteBuffer
    ) throws -> ClickHouseSerializationKind {
        guard revision >= Self.revisionWithCustomSerialization else {
            return .default
        }
        let hasCustom = try buffer.readClickHouseBool()
        guard hasCustom else { return .default }
        return try readCustomSerializationKind(from: &buffer)
    }

    private static func readCustomSerializationKind(from buffer: inout ByteBuffer) throws -> ClickHouseSerializationKind {
        guard let raw: UInt8 = buffer.readInteger() else {
            throw ClickHouseError.truncatedBuffer(needed: 1, available: buffer.readableBytes)
        }
        return try ClickHouseSerializationKind(rawByte: raw)
    }

    private static func decodeColumn(
        spec: ClickHouseColumnSpec,
        rows: Int,
        kind: ClickHouseSerializationKind,
        from buffer: inout ByteBuffer
    ) throws -> any ClickHouseColumn {
        switch kind {
        case .default:
            return try ClickHouseColumnRegistry.decode(spec: spec, rows: rows, from: &buffer)
        case .sparse:
            return try ClickHouseSparseColumnDecoder.decode(spec: spec, rows: rows, from: &buffer)
        }
    }

    private func assertConsistentRowCounts() throws {
        guard let firstRowCount = columns.first?.column.rowCount else { return }
        for (index, namedColumn) in columns.enumerated().dropFirst() {
            try Self.requireConsistentRowCount(columnIndex: index, expected: firstRowCount, actual: namedColumn.column.rowCount)
        }
    }

    private static func requireConsistentRowCount(columnIndex: Int, expected: Int, actual: Int) throws {
        guard actual == expected else {
            throw ClickHouseError.blockColumnRowCountMismatch(
                columnIndex: columnIndex,
                expected: expected,
                actual: actual
            )
        }
    }

    struct NamedColumn: Sendable {

        let name: String
        let column: any ClickHouseColumn

    }

}
