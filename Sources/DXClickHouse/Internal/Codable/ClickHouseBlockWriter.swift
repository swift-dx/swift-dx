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
//   BlockInfo prologue (matches `ClickHouseQueryBuilder.appendEmptyDataPacket`)
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
// count. The caller (ClickHouseRowEncoderStorage.materialize) only
// produces well-shaped columns, but a divergence here would surface a
// confusing server-side error, so a runtime check guards the assumption.
public enum ClickHouseBlockWriter {

    public static let revisionWithCustomSerialization: UInt64 = 54_454

    public static func encodeDataPacket(
        columns: [ClickHouseNamedColumn],
        revision: UInt64
    ) throws(ClickHouseError) -> [UInt8] {
        let rowCount = try sharedRowCount(columns: columns)
        var output: [UInt8] = []
        output.reserveCapacity(estimateCapacity(columns: columns, rowCount: rowCount))
        ClickHouseWire.writeUVarInt(2, into: &output) // packet type: Data
        ClickHouseWire.writeString("", into: &output) // table name
        appendBlockInfo(into: &output)
        ClickHouseWire.writeUVarInt(UInt64(columns.count), into: &output)
        ClickHouseWire.writeUVarInt(UInt64(rowCount), into: &output)
        for namedColumn in columns {
            ClickHouseWire.writeString(namedColumn.name, into: &output)
            ClickHouseWire.writeString(namedColumn.column.typeName, into: &output)
            if revision >= revisionWithCustomSerialization {
                output.append(0)
            }
            writeColumnBody(column: namedColumn.column, into: &output)
        }
        return output
    }

    // Empty Data packet that terminates the client-side INSERT stream.
    // Same as `ClickHouseQueryBuilder.appendEmptyDataPacket` but
    // produces a standalone packet rather than appending to a Query
    // packet's tail.
    public static func encodeEmptyDataPacket() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(16)
        ClickHouseWire.writeUVarInt(2, into: &output)
        ClickHouseWire.writeString("", into: &output)
        appendBlockInfo(into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output)
        return output
    }

    private static func sharedRowCount(columns: [ClickHouseNamedColumn]) throws(ClickHouseError) -> Int {
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
        ClickHouseWire.writeUVarInt(1, into: &output)
        output.append(0)
        ClickHouseWire.writeUVarInt(2, into: &output)
        ClickHouseWire.writeFixedInt(Int32(-1), into: &output)
        ClickHouseWire.writeUVarInt(0, into: &output)
    }

    private static func estimateCapacity(columns: [ClickHouseNamedColumn], rowCount: Int) -> Int {
        var bytes = 64 + columns.count * 32
        for namedColumn in columns {
            bytes += estimateColumnSize(column: namedColumn.column, rowCount: rowCount)
        }
        return bytes
    }

    private static func estimateColumnSize(column: ClickHouseTypedColumn, rowCount: Int) -> Int {
        switch column {
        case .bool, .uint8, .int8: rowCount
        case .uint16, .int16, .date: rowCount * 2
        case .uint32, .int32, .float32, .dateTime, .time: rowCount * 4
        case .uint64, .int64, .float64, .dateTime64, .time64: rowCount * 8
        case .uuid: rowCount * 16
        case .nullableBool, .nullableUInt8, .nullableInt8: rowCount * 2
        case .nullableUInt16, .nullableInt16: rowCount * 3
        case .nullableUInt32, .nullableInt32, .nullableFloat32, .nullableDateTime: rowCount * 5
        case .nullableUInt64, .nullableInt64, .nullableFloat64: rowCount * 9
        case .nullableUUID: rowCount * 17
        case .string(let values): values.reduce(0) { $0 + 10 + $1.utf8.count }
        case .nullableString(let values): rowCount + values.reduce(0) { $0 + 10 + presentStringByteCount($1) }
        case .fixedString(_, let length): rowCount * length
        case .enum8: rowCount
        case .enum16: rowCount * 2
        case .lowCardinality(let values, _): 32 + values.count * 24
        case .array(let values, _): rowCount * 8 + elementCount(values) * 24
        case .date32, .ipv4: rowCount * 4
        case .bfloat16: rowCount * 2
        case .ipv6, .int128, .uint128: rowCount * 16
        case .int256, .uint256: rowCount * 32
        case .json(let values): values.reduce(0) { $0 + 10 + $1.count }
        case .decimal(_, let precision, _): rowCount * ClickHouseDecimalWidth.bytes(forPrecision: precision)
        case .interval: rowCount * 8
        case .nothing: rowCount
        case .tuple(let columns, _): columns.reduce(0) { $0 + estimateColumnSize(column: $1, rowCount: rowCount) }
        case .map(let keys, let values, _, _):
            rowCount * 8 + (elementCount(keys) + elementCount(values)) * 24
        case .arrayOfTuple(let firstValues, let secondValues, _, _):
            rowCount * 8 + (elementCount(firstValues) + elementCount(secondValues)) * 24
        case .variant(_, _, let values):
            8 + rowCount + values.reduce(0) { $0 + 9 + $1.count }
        case .dynamic(let members, _, let values):
            16 + members.reduce(0) { $0 + $1.typeName.utf8.count + 2 } + rowCount + values.reduce(0) { $0 + 9 + $1.count }
        case .aggregateFunction(_, let states): states.reduce(0) { $0 + $1.count }
        case .nullable(let mask, let inner): mask.count + estimateColumnSize(column: inner, rowCount: rowCount)
        }
    }

    private static func elementCount(_ rows: [[[UInt8]]]) -> Int {
        var total = 0
        for row in rows { total += row.count }
        return total
    }

    private static func presentStringByteCount(_ nullable: ClickHouseNullable<String>) -> Int {
        switch nullable {
        case .present(let value): value.utf8.count
        case .absent: 0
        }
    }

    private static func writeColumnBody(column: ClickHouseTypedColumn, into output: inout [UInt8]) {
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
                ClickHouseWire.writeFixedInt(seconds, into: &output)
            }
        case .nullableDateTime(let values):
            writeNullMask(values, into: &output)
            for entry in values {
                let seconds: UInt32
                switch entry {
                case .present(let date): seconds = clampedUInt32Seconds(date)
                case .absent: seconds = 0
                }
                ClickHouseWire.writeFixedInt(seconds, into: &output)
            }
        case .dateTime64(let values, _):
            writeFixedWidthArray(values, into: &output)
        case .date(let values):
            writeFixedWidthArray(values, into: &output)
        case .time(let values):
            writeFixedWidthArray(values, into: &output)
        case .time64(let values, _):
            writeFixedWidthArray(values, into: &output)
        case .fixedString(let values, let length):
            for value in values { writeFixedStringValue(value, length: length, into: &output) }
        case .enum8(let values, _):
            for value in values { output.append(UInt8(bitPattern: value)) }
        case .enum16(let values, _):
            writeFixedWidthArray(values, into: &output)
        case .lowCardinality(let values, let inner):
            writeLowCardinality(values, inner: inner, into: &output)
        case .array(let values, let element):
            writeArray(values, element: element, into: &output)
        case .date32(let values):
            writeFixedWidthArray(values, into: &output)
        case .bfloat16(let values):
            writeFixedWidthArray(values, into: &output)
        case .ipv4(let values):
            writeFixedWidthArray(values, into: &output)
        case .ipv6(let values):
            for value in values { writeFixedStringValue(value, length: 16, into: &output) }
        case .int128(let values):
            writeFixedWidthArray(values, into: &output)
        case .uint128(let values):
            writeFixedWidthArray(values, into: &output)
        case .int256(let values):
            for value in values { writeInt256Limbs(value.limb0, value.limb1, value.limb2, value.limb3, into: &output) }
        case .uint256(let values):
            for value in values { writeInt256Limbs(value.limb0, value.limb1, value.limb2, value.limb3, into: &output) }
        case .json(let values):
            for value in values { writeLengthPrefixedBytes(value, into: &output) }
        case .decimal(let values, let precision, _):
            let width = ClickHouseDecimalWidth.bytes(forPrecision: precision)
            for value in values { writeDecimalLimbs(value, width: width, into: &output) }
        case .interval(let values, _):
            writeFixedWidthArray(values, into: &output)
        case .nothing(let rowCount):
            output.append(contentsOf: repeatElement(0, count: rowCount))
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
        case .tuple(let columns, _):
            for inner in columns { writeColumnBody(column: inner, into: &output) }
        case .map(let keys, let values, let keyElement, let valueElement):
            writeMap(keys: keys, values: values, keyElement: keyElement, valueElement: valueElement, into: &output)
        case .arrayOfTuple(let firstValues, let secondValues, let firstElement, let secondElement):
            writeMap(keys: firstValues, values: secondValues, keyElement: firstElement, valueElement: secondElement, into: &output)
        case .variant(let members, let discriminators, let values):
            writeVariant(members: members, discriminators: discriminators, values: values, into: &output)
        case .dynamic(let members, let discriminators, let values):
            ClickHouseDynamicPrefix.write(members: members, into: &output)
            writeDynamicVariantBody(members: members, discriminators: discriminators, values: values, into: &output)
        case .aggregateFunction(_, let states):
            for state in states { output.append(contentsOf: state) }
        case .nullable(let mask, let inner):
            for isNull in mask { output.append(isNull ? 1 : 0) }
            writeColumnBody(column: inner, into: &output)
        }
    }

    @inline(__always)
    private static func writeStrings(_ values: [String], into output: inout [UInt8]) {
        for value in values { ClickHouseWire.writeString(value, into: &output) }
    }

    @inline(__always)
    private static func writeNullableStrings(_ values: [ClickHouseNullable<String>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            switch entry {
            case .present(let value): ClickHouseWire.writeString(value, into: &output)
            case .absent: ClickHouseWire.writeString("", into: &output)
            }
        }
    }

    @inline(__always)
    private static func writeFixedWidthArray<T: FixedWidthInteger>(_ values: [T], into output: inout [UInt8]) {
        #if _endian(little)
        values.withUnsafeBytes { output.append(contentsOf: $0) }
        #else
        for value in values { ClickHouseWire.writeFixedInt(value, into: &output) }
        #endif
    }

    @inline(__always)
    private static func writeNullableFixedWidthArray<T: FixedWidthInteger>(_ values: [ClickHouseNullable<T>], sentinel: T, into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let stored: T
            switch entry {
            case .present(let value): stored = value
            case .absent: stored = sentinel
            }
            ClickHouseWire.writeFixedInt(stored, into: &output)
        }
    }

    @inline(__always)
    private static func writeFloat32Array(_ values: [Float], into output: inout [UInt8]) {
        #if _endian(little)
        values.withUnsafeBytes { output.append(contentsOf: $0) }
        #else
        for value in values { ClickHouseWire.writeFixedInt(value.bitPattern, into: &output) }
        #endif
    }

    @inline(__always)
    private static func writeFloat64Array(_ values: [Double], into output: inout [UInt8]) {
        #if _endian(little)
        values.withUnsafeBytes { output.append(contentsOf: $0) }
        #else
        for value in values { ClickHouseWire.writeFixedInt(value.bitPattern, into: &output) }
        #endif
    }

    @inline(__always)
    private static func writeNullableFloat32(_ values: [ClickHouseNullable<Float>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let bits: UInt32
            switch entry {
            case .present(let value): bits = value.bitPattern
            case .absent: bits = 0
            }
            ClickHouseWire.writeFixedInt(bits, into: &output)
        }
    }

    @inline(__always)
    private static func writeNullableFloat64(_ values: [ClickHouseNullable<Double>], into output: inout [UInt8]) {
        writeNullMask(values, into: &output)
        for entry in values {
            let bits: UInt64
            switch entry {
            case .present(let value): bits = value.bitPattern
            case .absent: bits = 0
            }
            ClickHouseWire.writeFixedInt(bits, into: &output)
        }
    }

    // ClickHouse LowCardinality serialization flag: bit 9 (HasAdditionalKeys)
    // marks the dictionary as carried inline in this block rather than
    // referenced from a shared global dictionary (bit 8). Native-format
    // inserts must set HasAdditionalKeys and must NOT set the global-
    // dictionary bit. The index width occupies the low byte.
    private static let lowCardinalityHasAdditionalKeysBit: UInt64 = 0x0200

    private static func writeLowCardinality(_ values: [[UInt8]], inner: ClickHouseLowCardinalityInner, into output: inout [UInt8]) {
        if values.isEmpty { return }
        var dictionary: [[UInt8]] = []
        var lookup: [[UInt8]: Int] = [:]
        lookup.reserveCapacity(values.count)
        var indices: [Int] = []
        indices.reserveCapacity(values.count)
        for value in values {
            if let existing = lookup[value] {
                indices.append(existing)
            } else {
                let assigned = dictionary.count
                dictionary.append(value)
                lookup[value] = assigned
                indices.append(assigned)
            }
        }
        let widthCode = lowCardinalityWidthCode(dictionarySize: dictionary.count)
        ClickHouseWire.writeFixedInt(UInt64(1), into: &output)
        ClickHouseWire.writeFixedInt(lowCardinalityHasAdditionalKeysBit | widthCode.code, into: &output)
        ClickHouseWire.writeFixedInt(UInt64(dictionary.count), into: &output)
        writeLowCardinalityDictionary(dictionary, inner: inner, into: &output)
        ClickHouseWire.writeFixedInt(UInt64(values.count), into: &output)
        for index in indices {
            writeLowCardinalityIndex(index, width: widthCode.width, into: &output)
        }
    }

    private static func lowCardinalityWidthCode(dictionarySize: Int) -> (code: UInt64, width: Int) {
        let maxIndex = dictionarySize - 1
        if maxIndex <= Int(UInt8.max) { return (0, 1) }
        if maxIndex <= Int(UInt16.max) { return (1, 2) }
        if maxIndex <= Int(UInt32.max) { return (2, 4) }
        return (3, 8)
    }

    private static func writeLowCardinalityDictionary(_ dictionary: [[UInt8]], inner: ClickHouseLowCardinalityInner, into output: inout [UInt8]) {
        switch inner {
        case .string:
            for value in dictionary { writeLengthPrefixedBytes(value, into: &output) }
        case .fixedString(let length):
            for value in dictionary { writeFixedStringValue(value, length: length, into: &output) }
        }
    }

    private static func writeLengthPrefixedBytes(_ bytes: [UInt8], into output: inout [UInt8]) {
        ClickHouseWire.writeUVarInt(UInt64(bytes.count), into: &output)
        output.append(contentsOf: bytes)
    }

    private static func writeLowCardinalityIndex(_ index: Int, width: Int, into output: inout [UInt8]) {
        switch width {
        case 1: output.append(UInt8(truncatingIfNeeded: index))
        case 2: ClickHouseWire.writeFixedInt(UInt16(truncatingIfNeeded: index), into: &output)
        case 4: ClickHouseWire.writeFixedInt(UInt32(truncatingIfNeeded: index), into: &output)
        default: ClickHouseWire.writeFixedInt(UInt64(truncatingIfNeeded: index), into: &output)
        }
    }

    @inline(__always)
    private static func writeInt256Limbs(_ limb0: UInt64, _ limb1: UInt64, _ limb2: UInt64, _ limb3: UInt64, into output: inout [UInt8]) {
        ClickHouseWire.writeFixedInt(limb0, into: &output)
        ClickHouseWire.writeFixedInt(limb1, into: &output)
        ClickHouseWire.writeFixedInt(limb2, into: &output)
        ClickHouseWire.writeFixedInt(limb3, into: &output)
    }

    @inline(__always)
    private static func writeDecimalLimbs(_ value: ClickHouseDecimal, width: Int, into output: inout [UInt8]) {
        switch width {
        case 4: ClickHouseWire.writeFixedInt(UInt32(truncatingIfNeeded: value.limb0), into: &output)
        case 8: ClickHouseWire.writeFixedInt(value.limb0, into: &output)
        case 16:
            ClickHouseWire.writeFixedInt(value.limb0, into: &output)
            ClickHouseWire.writeFixedInt(value.limb1, into: &output)
        default:
            writeInt256Limbs(value.limb0, value.limb1, value.limb2, value.limb3, into: &output)
        }
    }

    private static func writeArray(_ values: [[[UInt8]]], element: ClickHouseArrayElementType, into output: inout [UInt8]) {
        var cumulative: UInt64 = 0
        for row in values {
            cumulative += UInt64(row.count)
            ClickHouseWire.writeFixedInt(cumulative, into: &output)
        }
        for row in values {
            writeArrayElements(row, element: element, into: &output)
        }
    }

    private static func writeMap(
        keys: [[[UInt8]]],
        values: [[[UInt8]]],
        keyElement: ClickHouseArrayElementType,
        valueElement: ClickHouseArrayElementType,
        into output: inout [UInt8]
    ) {
        var cumulative: UInt64 = 0
        for row in keys {
            cumulative += UInt64(row.count)
            ClickHouseWire.writeFixedInt(cumulative, into: &output)
        }
        for row in keys {
            writeArrayElements(row, element: keyElement, into: &output)
        }
        for row in values {
            writeArrayElements(row, element: valueElement, into: &output)
        }
    }

    // Variant body: 8-byte basic-discriminators mode prefix (0), then one
    // discriminator byte per row (alphabetical member index, 255 = NULL),
    // then each member's sub-column in member-index order carrying only the
    // present rows' raw values in row order. The sub-column body is the
    // normal Native body for that member element type.
    private static func writeVariant(
        members: [ClickHouseArrayElementType],
        discriminators: [UInt8],
        values: [[UInt8]],
        into output: inout [UInt8]
    ) {
        ClickHouseWire.writeFixedInt(UInt64(0), into: &output)
        output.append(contentsOf: discriminators)
        for memberIndex in members.indices {
            let present = presentValues(forMember: UInt8(memberIndex), discriminators: discriminators, values: values)
            writeArrayElements(present, element: members[memberIndex], into: &output)
        }
    }

    // Dynamic embedded-Variant body: the 8-byte basic-discriminators mode
    // prefix (0), one global discriminator byte per row (255 = NULL), then
    // each member's sub-column in member-name-list order carrying only that
    // member's present rows. The discriminators are global (they account
    // for the hidden SharedVariant member), so each member's present rows
    // are selected by matching its global discriminator rather than its
    // member-list index.
    private static func writeDynamicVariantBody(
        members: [ClickHouseArrayElementType],
        discriminators: [UInt8],
        values: [[UInt8]],
        into output: inout [UInt8]
    ) {
        ClickHouseWire.writeFixedInt(UInt64(0), into: &output)
        output.append(contentsOf: discriminators)
        let globalDiscriminators = ClickHouseDynamicColumnBuilder.globalDiscriminators(of: members)
        for memberIndex in members.indices {
            let present = presentValues(forMember: globalDiscriminators[memberIndex], discriminators: discriminators, values: values)
            writeArrayElements(present, element: members[memberIndex], into: &output)
        }
    }

    private static func presentValues(forMember member: UInt8, discriminators: [UInt8], values: [[UInt8]]) -> [[UInt8]] {
        var present: [[UInt8]] = []
        for row in discriminators.indices where discriminators[row] == member {
            present.append(values[row])
        }
        return present
    }

    private static func writeArrayElements(_ elements: [[UInt8]], element: ClickHouseArrayElementType, into output: inout [UInt8]) {
        let width = element.fixedWidth
        if width < 0 {
            for value in elements { writeLengthPrefixedBytes(value, into: &output) }
        } else {
            for value in elements { writeFixedStringValue(value, length: width, into: &output) }
        }
    }

    @inline(__always)
    private static func writeFixedStringValue(_ value: [UInt8], length: Int, into output: inout [UInt8]) {
        if value.count == length {
            output.append(contentsOf: value)
            return
        }
        if value.count >= length {
            output.append(contentsOf: value[value.startIndex..<value.startIndex + length])
        } else {
            output.append(contentsOf: value)
            output.append(contentsOf: repeatElement(0, count: length - value.count))
        }
    }

    @inline(__always)
    private static func writeNullMask<Wrapped>(_ values: [ClickHouseNullable<Wrapped>], into output: inout [UInt8]) {
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
