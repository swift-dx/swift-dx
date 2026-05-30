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

// Serialises a list of typed columns into the wire bytes that the
// ClickHouse Native protocol uses for one Data packet's block payload:
//
//   UVarInt packetType = 2 (Data)
//   String  tableName  (always empty for client→server inserts)
//   BlockInfo prologue (matches `RawClickHouseQueryBuilder.appendEmptyDataPacket`)
//   UVarInt columnCount
//   UVarInt rowCount
//   for each column:
//     String  columnName
//     String  columnType  (Nullable(...) wrapping when applicable)
//     UInt8   hasCustomSerialization = 0     (revision >= 54_454)
//     (for Nullable) UInt8[rowCount] null mask
//     column body bytes (fixed-width or string vector)
//
// Two-row consistency rule: every column must report the same row
// count. The caller (RawClickHouseRowEncoderStorage.materialize) only
// produces well-shaped columns, but a divergence here would surface a
// confusing server-side error, so a runtime check guards the assumption.
public enum RawClickHouseBlockWriter {

    public static let revisionWithCustomSerialization: UInt64 = 54_454

    public static func encodeDataPacket(
        columns: [RawClickHouseNamedColumn],
        revision: UInt64
    ) throws(RawClickHouseError) -> [UInt8] {
        let rowCount = try sharedRowCount(columns: columns)
        var output: [UInt8] = []
        output.reserveCapacity(estimateCapacity(columns: columns, rowCount: rowCount))
        RawClickHouseWire.writeUVarInt(2, into: &output) // packet type: Data
        RawClickHouseWire.writeString("", into: &output) // table name
        appendBlockInfo(into: &output)
        RawClickHouseWire.writeUVarInt(UInt64(columns.count), into: &output)
        RawClickHouseWire.writeUVarInt(UInt64(rowCount), into: &output)
        for namedColumn in columns {
            RawClickHouseWire.writeString(namedColumn.name, into: &output)
            RawClickHouseWire.writeString(namedColumn.column.typeName, into: &output)
            if revision >= revisionWithCustomSerialization {
                output.append(0)
            }
            writeColumnBody(column: namedColumn.column, into: &output)
        }
        return output
    }

    // Empty Data packet that terminates the client-side INSERT stream.
    // Same as `RawClickHouseQueryBuilder.appendEmptyDataPacket` but
    // produces a standalone packet rather than appending to a Query
    // packet's tail.
    public static func encodeEmptyDataPacket() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(16)
        RawClickHouseWire.writeUVarInt(2, into: &output)
        RawClickHouseWire.writeString("", into: &output)
        appendBlockInfo(into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output)
        return output
    }

    private static func sharedRowCount(columns: [RawClickHouseNamedColumn]) throws(RawClickHouseError) -> Int {
        guard let first = columns.first else { return 0 }
        let expected = first.column.rowCount
        for column in columns.dropFirst() where column.column.rowCount != expected {
            throw .protocolError(
                stage: "blockWriter",
                message: "column '\(column.name)' has rowCount \(column.column.rowCount); expected \(expected) from column '\(first.name)'"
            )
        }
        return expected
    }

    private static func appendBlockInfo(into output: inout [UInt8]) {
        RawClickHouseWire.writeUVarInt(1, into: &output)
        output.append(0)
        RawClickHouseWire.writeUVarInt(2, into: &output)
        RawClickHouseWire.writeFixedInt(Int32(-1), into: &output)
        RawClickHouseWire.writeUVarInt(0, into: &output)
    }

    private static func estimateCapacity(columns: [RawClickHouseNamedColumn], rowCount: Int) -> Int {
        var bytes = 64 + columns.count * 32
        for namedColumn in columns {
            bytes += estimateColumnSize(column: namedColumn.column, rowCount: rowCount)
        }
        return bytes
    }

    private static func estimateColumnSize(column: RawClickHouseTypedColumn, rowCount: Int) -> Int {
        switch column {
        case .bool, .uint8, .int8: rowCount
        case .uint16, .int16: rowCount * 2
        case .uint32, .int32, .float32, .dateTime: rowCount * 4
        case .uint64, .int64, .float64: rowCount * 8
        case .uuid: rowCount * 16
        case .nullableBool, .nullableUInt8, .nullableInt8: rowCount * 2
        case .nullableUInt16, .nullableInt16: rowCount * 3
        case .nullableUInt32, .nullableInt32, .nullableFloat32, .nullableDateTime: rowCount * 5
        case .nullableUInt64, .nullableInt64, .nullableFloat64: rowCount * 9
        case .nullableUUID: rowCount * 17
        case .string(let values): values.reduce(0) { $0 + 10 + $1.utf8.count }
        case .nullableString(let values): rowCount + values.reduce(0) { $0 + 10 + presentStringByteCount($1) }
        }
    }

    private static func presentStringByteCount(_ nullable: RawClickHouseNullable<String>) -> Int {
        switch nullable {
        case .present(let value): value.utf8.count
        case .absent: 0
        }
    }

    private static func writeColumnBody(column: RawClickHouseTypedColumn, into output: inout [UInt8]) {
        switch column {
        case .string(let values): writeStrings(values, into: &output)
        case .nullableString(let values): writeNullableStrings(values, into: &output)
        case .bool(let values):
            for value in values { output.append(value ? 1 : 0) }
        case .nullableBool(let values):
            writeNullMask(values, into: &output)
            for entry in values {
                switch entry {
                case .present(let value): output.append(value ? 1 : 0)
                case .absent: output.append(0)
                }
            }
        case .int8(let values):
            for value in values { output.append(UInt8(bitPattern: value)) }
        case .int16(let values): writeFixedWidthArray(values, into: &output)
        case .int32(let values): writeFixedWidthArray(values, into: &output)
        case .int64(let values): writeFixedWidthArray(values, into: &output)
        case .nullableInt8(let values): writeNullableFixedWidthArray(values, sentinel: Int8(0), into: &output)
        case .nullableInt16(let values): writeNullableFixedWidthArray(values, sentinel: Int16(0), into: &output)
        case .nullableInt32(let values): writeNullableFixedWidthArray(values, sentinel: Int32(0), into: &output)
        case .nullableInt64(let values): writeNullableFixedWidthArray(values, sentinel: Int64(0), into: &output)
        case .uint8(let values): output.append(contentsOf: values)
        case .uint16(let values): writeFixedWidthArray(values, into: &output)
        case .uint32(let values): writeFixedWidthArray(values, into: &output)
        case .uint64(let values): writeFixedWidthArray(values, into: &output)
        case .nullableUInt8(let values): writeNullableFixedWidthArray(values, sentinel: UInt8(0), into: &output)
        case .nullableUInt16(let values): writeNullableFixedWidthArray(values, sentinel: UInt16(0), into: &output)
        case .nullableUInt32(let values): writeNullableFixedWidthArray(values, sentinel: UInt32(0), into: &output)
        case .nullableUInt64(let values): writeNullableFixedWidthArray(values, sentinel: UInt64(0), into: &output)
        case .float32(let values): writeFloat32Array(values, into: &output)
        case .float64(let values): writeFloat64Array(values, into: &output)
        case .nullableFloat32(let values): writeNullableFloat32(values, into: &output)
        case .nullableFloat64(let values): writeNullableFloat64(values, into: &output)
        case .dateTime(let values):
            for date in values {
                let seconds = clampedUInt32Seconds(date)
                RawClickHouseWire.writeFixedInt(seconds, into: &output)
            }
        case .nullableDateTime(let values):
            writeNullMask(values, into: &output)
            for entry in values {
                let seconds: UInt32
                switch entry {
                case .present(let date): seconds = clampedUInt32Seconds(date)
                case .absent: seconds = 0
                }
                RawClickHouseWire.writeFixedInt(seconds, into: &output)
            }
        case .uuid(let values):
            for uuid in values { appendUUID(uuid, into: &output) }
        case .nullableUUID(let values):
            writeNullMask(values, into: &output)
            for entry in values {
                switch entry {
                case .present(let uuid): appendUUID(uuid, into: &output)
                case .absent: output.append(contentsOf: repeatElement(0, count: 16))
                }
            }
        }
    }

    @inline(__always)
    private static func writeStrings(_ values: [String], into output: inout [UInt8]) {
        for value in values { RawClickHouseWire.writeString(value, into: &output) }
    }

    @inline(__always)
    private static func writeNullableStrings(_ values: [RawClickHouseNullable<String>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            switch entry {
            case .present(let value): RawClickHouseWire.writeString(value, into: &output)
            case .absent: RawClickHouseWire.writeString("", into: &output)
            }
        }
    }

    @inline(__always)
    private static func writeFixedWidthArray<T: FixedWidthInteger>(_ values: [T], into output: inout [UInt8]) {
        for value in values { RawClickHouseWire.writeFixedInt(value, into: &output) }
    }

    @inline(__always)
    private static func writeNullableFixedWidthArray<T: FixedWidthInteger>(_ values: [RawClickHouseNullable<T>], sentinel: T, into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let stored: T
            switch entry {
            case .present(let value): stored = value
            case .absent: stored = sentinel
            }
            RawClickHouseWire.writeFixedInt(stored, into: &output)
        }
    }

    @inline(__always)
    private static func writeFloat32Array(_ values: [Float], into output: inout [UInt8]) {
        for value in values { RawClickHouseWire.writeFixedInt(value.bitPattern, into: &output) }
    }

    @inline(__always)
    private static func writeFloat64Array(_ values: [Double], into output: inout [UInt8]) {
        for value in values { RawClickHouseWire.writeFixedInt(value.bitPattern, into: &output) }
    }

    @inline(__always)
    private static func writeNullableFloat32(_ values: [RawClickHouseNullable<Float>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let bits: UInt32
            switch entry {
            case .present(let value): bits = value.bitPattern
            case .absent: bits = 0
            }
            RawClickHouseWire.writeFixedInt(bits, into: &output)
        }
    }

    @inline(__always)
    private static func writeNullableFloat64(_ values: [RawClickHouseNullable<Double>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let bits: UInt64
            switch entry {
            case .present(let value): bits = value.bitPattern
            case .absent: bits = 0
            }
            RawClickHouseWire.writeFixedInt(bits, into: &output)
        }
    }

    @inline(__always)
    private static func writeNullMask<Wrapped>(_ values: [RawClickHouseNullable<Wrapped>], into output: inout [UInt8]) {
        for entry in values { output.append(entry.isAbsent ? 1 : 0) }
    }

    @inline(__always)
    private static func clampedUInt32Seconds(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970
        if seconds <= 0 { return 0 }
        if seconds >= Double(UInt32.max) { return UInt32.max }
        return UInt32(seconds)
    }

    @inline(__always)
    private static func appendUUID(_ uuid: UUID, into output: inout [UInt8]) {
        // ClickHouse UUID storage: two little-endian UInt64 halves where
        // the first half holds bytes 0-7 reversed and the second half
        // holds bytes 8-15 reversed (relative to the network/text form).
        // Equivalently, swap each 8-byte half end-to-end before writing.
        let bytes = uuid.uuid
        let first: [UInt8] = [
            bytes.7, bytes.6, bytes.5, bytes.4,
            bytes.3, bytes.2, bytes.1, bytes.0,
        ]
        let second: [UInt8] = [
            bytes.15, bytes.14, bytes.13, bytes.12,
            bytes.11, bytes.10, bytes.9, bytes.8,
        ]
        output.append(contentsOf: first)
        output.append(contentsOf: second)
    }
}
