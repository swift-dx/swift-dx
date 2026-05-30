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

import Foundation

// Block → typed columns → [T] driver. Consumed by the typed select path
// on the raw transport: each Data block delivered via
// `RawClickHouseConnection.receiveBlocks` is handed here, the per-column
// bodies are parsed into Swift-native typed buffers, and then each
// row is materialised via Codable's `T.init(from:)` against the columnar
// decoder.
//
// The body bytes match the layout produced by `copyColumnBody` on the
// transport: for fixed-width column types the body is N elements of the
// type's wire width concatenated; for variable-width String columns the
// body is N length-prefixed UVarInt+bytes pairs; for Nullable(T) columns
// the body is N null-mask bytes followed by N inner-type values. The
// raw transport's existing block parser knows the column type names and
// hands them in the block header.
public enum RawClickHouseCodableDecoder {

    public static func parseTypedColumns(
        block: RawClickHouseBlock,
        body: UnsafeRawBufferPointer
    ) throws(RawClickHouseError) -> [RawClickHouseNamedColumn] {
        guard let base = body.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            if block.rowCount == 0 { return [] }
            throw .protocolError(stage: "decoder.parseTypedColumns", message: "block body pointer is nil")
        }
        var cursor = 0
        let limit = body.count
        var columns: [RawClickHouseNamedColumn] = []
        columns.reserveCapacity(block.columnCount)
        for index in 0..<block.columnCount {
            let typeName = block.columnTypes[index]
            let name = block.columnNames[index]
            let parsed = try parseColumn(
                typeName: typeName,
                rowCount: block.rowCount,
                base: base,
                offset: cursor,
                limit: limit
            )
            columns.append(RawClickHouseNamedColumn(name: name, column: parsed.column))
            cursor = parsed.nextOffset
        }
        return columns
    }

    public static func decodeRows<T: Decodable>(
        type: T.Type,
        columns: [RawClickHouseNamedColumn],
        rowCount: Int
    ) throws(RawClickHouseError) -> [T] {
        if rowCount == 0 { return [] }
        let state = RawClickHouseColumnarDecoderState(columns: columns)
        var rows: [T] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            state.rowIndex = rowIndex
            let decoder = RawClickHouseColumnarDecoder(state: state)
            do {
                rows.append(try T(from: decoder))
            } catch let error as RawClickHouseError {
                throw error
            } catch {
                throw .protocolError(
                    stage: "decoder.decodeRows",
                    message: "row \(rowIndex) decode failed: \(error)"
                )
            }
        }
        return rows
    }

    private struct ColumnParseResult {
        let column: RawClickHouseTypedColumn
        let nextOffset: Int
    }

    private static func parseColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(RawClickHouseError) -> ColumnParseResult {
        if typeName.hasPrefix("Nullable(") {
            return try parseNullableColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        return try parseNonNullColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
    }

    private static func parseNonNullColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(RawClickHouseError) -> ColumnParseResult {
        switch typeName {
        case "String":
            let (values, consumed) = try parseStringColumn(rowCount: rowCount, base: base, offset: offset, limit: limit)
            return .init(column: .string(values), nextOffset: offset + consumed)
        case "Bool":
            try requireBytes(rowCount, available: limit - offset, typeName: typeName)
            var values = [Bool](); values.reserveCapacity(rowCount)
            for index in 0..<rowCount { values.append(base[offset + index] != 0) }
            return .init(column: .bool(values), nextOffset: offset + rowCount)
        case "Int8":
            try requireBytes(rowCount, available: limit - offset, typeName: typeName)
            var values = [Int8](); values.reserveCapacity(rowCount)
            for index in 0..<rowCount { values.append(Int8(bitPattern: base[offset + index])) }
            return .init(column: .int8(values), nextOffset: offset + rowCount)
        case "UInt8":
            try requireBytes(rowCount, available: limit - offset, typeName: typeName)
            var values = [UInt8](repeating: 0, count: rowCount)
            values.withUnsafeMutableBufferPointer { destination in
                guard let target = destination.baseAddress else { return }
                target.update(from: base + offset, count: rowCount)
            }
            return .init(column: .uint8(values), nextOffset: offset + rowCount)
        case "Int16":
            let values: [Int16] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .int16(values), nextOffset: offset + rowCount * 2)
        case "UInt16":
            let values: [UInt16] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .uint16(values), nextOffset: offset + rowCount * 2)
        case "Int32":
            let values: [Int32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .int32(values), nextOffset: offset + rowCount * 4)
        case "UInt32":
            let values: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .uint32(values), nextOffset: offset + rowCount * 4)
        case "Int64":
            let values: [Int64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .int64(values), nextOffset: offset + rowCount * 8)
        case "UInt64":
            let values: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .uint64(values), nextOffset: offset + rowCount * 8)
        case "Float32":
            let bits: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .float32(bits.map { Float(bitPattern: $0) }), nextOffset: offset + rowCount * 4)
        case "Float64":
            let bits: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .float64(bits.map { Double(bitPattern: $0) }), nextOffset: offset + rowCount * 8)
        case "DateTime":
            let raw: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .dateTime(raw.map { Date(timeIntervalSince1970: TimeInterval($0)) }), nextOffset: offset + rowCount * 4)
        case "UUID":
            try requireBytes(rowCount * 16, available: limit - offset, typeName: typeName)
            var values = [UUID](); values.reserveCapacity(rowCount)
            for index in 0..<rowCount {
                values.append(decodeUUID(base: base, offset: offset + index * 16))
            }
            return .init(column: .uuid(values), nextOffset: offset + rowCount * 16)
        default:
            if typeName.hasPrefix("DateTime(") {
                let raw: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
                return .init(column: .dateTime(raw.map { Date(timeIntervalSince1970: TimeInterval($0)) }), nextOffset: offset + rowCount * 4)
            }
            throw .protocolError(stage: "decoder.parseColumn", message: "unsupported column type \(typeName)")
        }
    }

    private static func parseNullableColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(RawClickHouseError) -> ColumnParseResult {
        try requireBytes(rowCount, available: limit - offset, typeName: typeName)
        let maskOffset = offset
        let mask = UnsafeBufferPointer(start: base + maskOffset, count: rowCount)
        let innerStart = offset + rowCount
        let innerType = String(typeName.dropFirst("Nullable(".count).dropLast())
        let inner = try parseNonNullColumn(typeName: innerType, rowCount: rowCount, base: base, offset: innerStart, limit: limit)
        let column = try mergeMaskIntoColumn(mask: mask, inner: inner.column)
        return .init(column: column, nextOffset: inner.nextOffset)
    }

    private static func mergeMaskIntoColumn(
        mask: UnsafeBufferPointer<UInt8>,
        inner: RawClickHouseTypedColumn
    ) throws(RawClickHouseError) -> RawClickHouseTypedColumn {
        switch inner {
        case .string(let values): return .nullableString(mergeMask(mask, values: values))
        case .bool(let values): return .nullableBool(mergeMask(mask, values: values))
        case .int8(let values): return .nullableInt8(mergeMask(mask, values: values))
        case .int16(let values): return .nullableInt16(mergeMask(mask, values: values))
        case .int32(let values): return .nullableInt32(mergeMask(mask, values: values))
        case .int64(let values): return .nullableInt64(mergeMask(mask, values: values))
        case .uint8(let values): return .nullableUInt8(mergeMask(mask, values: values))
        case .uint16(let values): return .nullableUInt16(mergeMask(mask, values: values))
        case .uint32(let values): return .nullableUInt32(mergeMask(mask, values: values))
        case .uint64(let values): return .nullableUInt64(mergeMask(mask, values: values))
        case .float32(let values): return .nullableFloat32(mergeMask(mask, values: values))
        case .float64(let values): return .nullableFloat64(mergeMask(mask, values: values))
        case .dateTime(let values): return .nullableDateTime(mergeMask(mask, values: values))
        case .uuid(let values): return .nullableUUID(mergeMask(mask, values: values))
        default:
            throw .protocolError(stage: "decoder.mergeNullableMask", message: "inner type unsupported in Nullable wrap")
        }
    }

    private static func mergeMask<T: Sendable>(_ mask: UnsafeBufferPointer<UInt8>, values: [T]) -> [RawClickHouseNullable<T>] {
        var result = [RawClickHouseNullable<T>](); result.reserveCapacity(values.count)
        for index in 0..<values.count {
            result.append(mask[index] != 0 ? .absent : .present(values[index]))
        }
        return result
    }

    private static func parseStringColumn(
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(RawClickHouseError) -> ([String], Int) {
        var values: [String] = []
        values.reserveCapacity(rowCount)
        var cursor = offset
        for _ in 0..<rowCount {
            do {
                let parsed = try RawClickHouseWire.readString(base: base, offset: cursor, limit: limit)
                values.append(parsed.0)
                cursor += parsed.1
            } catch {
                throw .protocolError(stage: "decoder.parseStringColumn", message: "\(error)")
            }
        }
        return (values, cursor - offset)
    }

    private static func parseFixedWidth<T: FixedWidthInteger>(
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        typeName: String
    ) throws(RawClickHouseError) -> [T] {
        let size = MemoryLayout<T>.size
        let total = rowCount * size
        try requireBytes(total, available: limit - offset, typeName: typeName)
        var values = [T](repeating: 0, count: rowCount)
        values.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            for index in 0..<rowCount {
                var value: T = 0
                withUnsafeMutableBytes(of: &value) { raw in
                    raw.copyMemory(from: UnsafeRawBufferPointer(start: base + offset + index * size, count: size))
                }
                target[index] = T(littleEndian: value)
            }
        }
        return values
    }

    @inline(__always)
    private static func decodeUUID(base: UnsafePointer<UInt8>, offset: Int) -> UUID {
        // Inverse of `RawClickHouseBlockWriter.appendUUID`: swap each
        // 8-byte half end-to-end. ClickHouse stores UUIDs as two
        // little-endian UInt64 halves; we reconstitute the text-form
        // byte order here.
        let bytes = (
            base[offset + 7], base[offset + 6], base[offset + 5], base[offset + 4],
            base[offset + 3], base[offset + 2], base[offset + 1], base[offset + 0],
            base[offset + 15], base[offset + 14], base[offset + 13], base[offset + 12],
            base[offset + 11], base[offset + 10], base[offset + 9], base[offset + 8]
        )
        return UUID(uuid: bytes)
    }

    private static func requireBytes(_ needed: Int, available: Int, typeName: String) throws(RawClickHouseError) {
        if available < needed {
            throw .protocolError(stage: "decoder.requireBytes", message: "column \(typeName) needs \(needed) bytes, \(available) available")
        }
    }
}
