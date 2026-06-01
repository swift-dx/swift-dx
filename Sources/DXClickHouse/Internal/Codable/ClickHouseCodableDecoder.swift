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
// `ClickHouseConnection.receiveBlocks` is handed here, the per-column
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
public enum ClickHouseCodableDecoder {

    public static func parseTypedColumns(
        block: ClickHouseBlock,
        body: UnsafeRawBufferPointer
    ) throws(ClickHouseError) -> [ClickHouseNamedColumn] {
        guard let base = body.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return try emptyOrThrowMissingBody(block: block)
        }
        return try walkColumns(block: block, base: base, limit: body.count)
    }

    private static func emptyOrThrowMissingBody(block: ClickHouseBlock) throws(ClickHouseError) -> [ClickHouseNamedColumn] {
        if block.rowCount == 0 { return [] }
        throw .protocolError(stage: "decoder.parseTypedColumns", message: "block body pointer is nil")
    }

    private static func walkColumns(
        block: ClickHouseBlock,
        base: UnsafePointer<UInt8>,
        limit: Int
    ) throws(ClickHouseError) -> [ClickHouseNamedColumn] {
        var cursor = 0
        var columns: [ClickHouseNamedColumn] = []
        columns.reserveCapacity(block.columnCount)
        for index in 0..<block.columnCount {
            let parsed = try parseColumn(
                typeName: block.columnTypes[index],
                rowCount: block.rowCount,
                base: base,
                offset: cursor,
                limit: limit
            )
            columns.append(ClickHouseNamedColumn(name: block.columnNames[index], column: parsed.column))
            cursor = parsed.nextOffset
        }
        return columns
    }

    public static func decodeRows<T: Decodable>(
        type: T.Type,
        columns: [ClickHouseNamedColumn],
        rowCount: Int
    ) throws(ClickHouseError) -> [T] {
        if rowCount == 0 { return [] }
        let state = ClickHouseColumnarDecoderState(columns: columns)
        var rows: [T] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            try decodeOneRow(into: &rows, type: T.self, state: state, rowIndex: rowIndex)
        }
        return rows
    }

    private static func decodeOneRow<T: Decodable>(
        into rows: inout [T],
        type: T.Type,
        state: ClickHouseColumnarDecoderState,
        rowIndex: Int
    ) throws(ClickHouseError) {
        state.rowIndex = rowIndex
        let decoder = ClickHouseColumnarDecoder(state: state)
        do {
            rows.append(try T(from: decoder))
        } catch let error as ClickHouseError {
            throw error
        } catch {
            throw .protocolError(
                stage: "decoder.decodeRows",
                message: "row \(rowIndex) decode failed: \(error)"
            )
        }
    }

    private struct ColumnParseResult {
        let column: ClickHouseTypedColumn
        let nextOffset: Int
    }

    private static func parseColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
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
    ) throws(ClickHouseError) -> ColumnParseResult {
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
        case "Date32":
            let values: [Int32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .date32(values), nextOffset: offset + rowCount * 4)
        case "BFloat16":
            let values: [UInt16] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .bfloat16(values), nextOffset: offset + rowCount * 2)
        case "Date":
            let values: [UInt16] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .date(values), nextOffset: offset + rowCount * 2)
        case "Time":
            let values: [Int32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .time(values), nextOffset: offset + rowCount * 4)
        case "IPv4":
            let values: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .ipv4(values), nextOffset: offset + rowCount * 4)
        case "IPv6":
            try requireBytes(rowCount * 16, available: limit - offset, typeName: typeName)
            var values: [[UInt8]] = []
            values.reserveCapacity(rowCount)
            for index in 0..<rowCount {
                let start = offset + index * 16
                var bytes = [UInt8](repeating: 0, count: 16)
                bytes.withUnsafeMutableBufferPointer { destination in
                    guard let target = destination.baseAddress else { return }
                    target.update(from: base + start, count: 16)
                }
                values.append(bytes)
            }
            return .init(column: .ipv6(values), nextOffset: offset + rowCount * 16)
        case "Int128":
            let values: [Int128] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .int128(values), nextOffset: offset + rowCount * 16)
        case "UInt128":
            let values: [UInt128] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
            return .init(column: .uint128(values), nextOffset: offset + rowCount * 16)
        case "Int256":
            try requireBytes(rowCount * 32, available: limit - offset, typeName: typeName)
            var values: [ClickHouseInt256] = []
            values.reserveCapacity(rowCount)
            for index in 0..<rowCount {
                let limbs = read256Limbs(base: base, offset: offset + index * 32)
                values.append(ClickHouseInt256(limb0: limbs.0, limb1: limbs.1, limb2: limbs.2, limb3: limbs.3))
            }
            return .init(column: .int256(values), nextOffset: offset + rowCount * 32)
        case "UInt256":
            try requireBytes(rowCount * 32, available: limit - offset, typeName: typeName)
            var values: [ClickHouseUInt256] = []
            values.reserveCapacity(rowCount)
            for index in 0..<rowCount {
                let limbs = read256Limbs(base: base, offset: offset + index * 32)
                values.append(ClickHouseUInt256(limb0: limbs.0, limb1: limbs.1, limb2: limbs.2, limb3: limbs.3))
            }
            return .init(column: .uint256(values), nextOffset: offset + rowCount * 32)
        case "Nothing":
            try requireBytes(rowCount, available: limit - offset, typeName: typeName)
            return .init(column: .nothing(rowCount: rowCount), nextOffset: offset + rowCount)
        default:
            if typeName.hasPrefix("DateTime64(") {
                let precision = try parseDateTime64Precision(typeName: typeName)
                let ticks: [Int64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
                return .init(column: .dateTime64(ticks, precision: precision), nextOffset: offset + rowCount * 8)
            }
            if typeName.hasPrefix("Time64(") {
                let precision = try parseParenthesizedPrecision(typeName: typeName, prefix: "Time64(", stage: "decoder.time64")
                let ticks: [Int64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
                return .init(column: .time64(ticks, precision: precision), nextOffset: offset + rowCount * 8)
            }
            if typeName.hasPrefix("DateTime(") {
                let raw: [UInt32] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
                return .init(column: .dateTime(raw.map { Date(timeIntervalSince1970: TimeInterval($0)) }), nextOffset: offset + rowCount * 4)
            }
            if typeName.hasPrefix("FixedString(") {
                return try parseFixedStringColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Enum8(") {
                return try parseEnum8Column(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Enum16(") {
                return try parseEnum16Column(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("LowCardinality(") {
                return try parseLowCardinalityColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Array(") {
                return try parseArrayColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Decimal") {
                return try parseDecimalColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Tuple(") {
                return try parseTupleColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Map(") {
                return try parseMapColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("Variant(") {
                return try parseVariantColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName == "Dynamic" || typeName.hasPrefix("Dynamic(") {
                return try parseDynamicColumn(rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if typeName.hasPrefix("AggregateFunction(") {
                return try parseAggregateFunctionColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
            }
            if ClickHouseIntervalKind.isKindName(typeName) {
                let kind = try ClickHouseIntervalKind(typeName: typeName)
                let values: [Int64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
                return .init(column: .interval(values, kind: kind), nextOffset: offset + rowCount * 8)
            }
            throw .protocolError(stage: "decoder.parseColumn", message: "unsupported column type \(typeName)")
        }
    }

    private static func parseArrayColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let inner = String(typeName.dropFirst("Array(".count).dropLast())
        if inner.hasPrefix("Tuple(") {
            return try parseArrayOfTupleColumn(innerTupleTypeName: inner, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        let element = try parseArrayElementType(typeName: typeName)
        if rowCount == 0 {
            return .init(column: .array([], element: element), nextOffset: offset)
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        var cursor = offset + rowCount * 8
        let totalElements = Int(offsets[rowCount - 1])
        let flat = try readArrayElements(element: element, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flat.nextOffset
        let perRow = try groupArrayElements(flat.elements, offsets: offsets, typeName: typeName)
        return .init(column: .array(perRow, element: element), nextOffset: cursor)
    }

    private static func parseTupleColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: typeName)
        var cursor = offset
        var columns: [ClickHouseTypedColumn] = []
        var names: [String] = []
        columns.reserveCapacity(elements.count)
        names.reserveCapacity(elements.count)
        for element in elements {
            let parsed = try parseColumn(typeName: element.type, rowCount: rowCount, base: base, offset: cursor, limit: limit)
            columns.append(parsed.column)
            names.append(element.name)
            cursor = parsed.nextOffset
        }
        let resolvedNames = ClickHouseTupleTypeSplitter.allNamed(names) ? names : []
        return .init(column: .tuple(columns, names: resolvedNames), nextOffset: cursor)
    }

    private static func parseMapColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let elementTypes = try parseMapElementTypes(typeName: typeName)
        if rowCount == 0 {
            return .init(
                column: .map(keys: [], values: [], keyElement: elementTypes.key, valueElement: elementTypes.value),
                nextOffset: offset
            )
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        var cursor = offset + rowCount * 8
        let totalElements = Int(offsets[rowCount - 1])
        let flatKeys = try readArrayElements(element: elementTypes.key, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flatKeys.nextOffset
        let flatValues = try readArrayElements(element: elementTypes.value, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flatValues.nextOffset
        let perRowKeys = try groupArrayElements(flatKeys.elements, offsets: offsets, typeName: typeName)
        let perRowValues = try groupArrayElements(flatValues.elements, offsets: offsets, typeName: typeName)
        return .init(
            column: .map(keys: perRowKeys, values: perRowValues, keyElement: elementTypes.key, valueElement: elementTypes.value),
            nextOffset: cursor
        )
    }

    private static func parseVariantColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let members = try parseVariantMemberTypes(typeName: typeName)
        if rowCount == 0 {
            return .init(column: .variant(members: members, discriminators: [], values: []), nextOffset: offset)
        }
        try requireBytes(8 + rowCount, available: limit - offset, typeName: typeName)
        let discriminators = readVariantDiscriminators(rowCount: rowCount, base: base, offset: offset + 8)
        var cursor = offset + 8 + rowCount
        var values = [[UInt8]](repeating: [], count: rowCount)
        for memberIndex in members.indices {
            let rowsForMember = rowIndices(discriminators: discriminators, member: UInt8(memberIndex))
            let elements = try readArrayElements(element: members[memberIndex], count: rowsForMember.count, base: base, offset: cursor, limit: limit, typeName: typeName)
            cursor = elements.nextOffset
            for position in rowsForMember.indices {
                values[rowsForMember[position]] = elements.elements[position]
            }
        }
        return .init(column: .variant(members: members, discriminators: discriminators, values: values), nextOffset: cursor)
    }

    private static func readVariantDiscriminators(rowCount: Int, base: UnsafePointer<UInt8>, offset: Int) -> [UInt8] {
        var discriminators = [UInt8](repeating: 0, count: rowCount)
        discriminators.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            target.update(from: base + offset, count: rowCount)
        }
        return discriminators
    }

    private static func rowIndices(discriminators: [UInt8], member: UInt8) -> [Int] {
        var indices: [Int] = []
        for row in discriminators.indices where discriminators[row] == member {
            indices.append(row)
        }
        return indices
    }

    private static func parseVariantMemberTypes(typeName: String) throws(ClickHouseError) -> [ClickHouseArrayElementType] {
        let inner = String(typeName.dropFirst("Variant(".count).dropLast())
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: "Tuple(\(inner))")
        var members: [ClickHouseArrayElementType] = []
        members.reserveCapacity(elements.count)
        for element in elements {
            members.append(try parseMapElementType(typeName: element.type, mapTypeName: typeName))
        }
        return members
    }

    // Dynamic body: an 8-byte structure-version prefix (1), a uvarint
    // max-dynamic-types limit, a uvarint member count, that many member
    // type-name strings (canonical sorted order), then an embedded Variant
    // body (8-byte data-mode prefix, one discriminator byte per row, and
    // each member's present-only sub-column). ClickHouse may assign the
    // discriminator array non-contiguous global values even on a fresh
    // insert (e.g. {0, 2, 3} for a three-member column), so the raw
    // discriminators are re-mapped to contiguous member positions by
    // aligning the ascending distinct present discriminators to the
    // member list in order. The produced column carries the normalized
    // member-position discriminators (255 = NULL) so the row decoder reads
    // it identically to a Variant.
    private static func parseDynamicColumn(
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        if rowCount == 0 {
            return .init(column: .dynamic(members: [], discriminators: [], values: []), nextOffset: offset)
        }
        let prefix = try readDynamicPrefix(base: base, offset: offset, limit: limit)
        let members = prefix.members
        try requireBytes(8 + rowCount, available: limit - prefix.nextOffset, typeName: "Dynamic")
        let rawDiscriminators = readVariantDiscriminators(rowCount: rowCount, base: base, offset: prefix.nextOffset + 8)
        let normalized = normalizeDynamicDiscriminators(rawDiscriminators, memberCount: members.count)
        var cursor = prefix.nextOffset + 8 + rowCount
        var values = [[UInt8]](repeating: [], count: rowCount)
        for memberIndex in members.indices {
            let rowsForMember = rowIndices(discriminators: normalized, member: UInt8(memberIndex))
            let elements = try readArrayElements(element: members[memberIndex], count: rowsForMember.count, base: base, offset: cursor, limit: limit, typeName: "Dynamic")
            cursor = elements.nextOffset
            for position in rowsForMember.indices {
                values[rowsForMember[position]] = elements.elements[position]
            }
        }
        return .init(column: .dynamic(members: members, discriminators: normalized, values: values), nextOffset: cursor)
    }

    private struct DynamicPrefix {
        let members: [ClickHouseArrayElementType]
        let nextOffset: Int
    }

    private static func readDynamicPrefix(
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> DynamicPrefix {
        do {
            let version = try ClickHouseWire.readFixedInt(UInt64.self, base: base, offset: offset, limit: limit)
            var cursor = offset + 8
            if version.0 == 1 {
                let maxTypes = try ClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
                cursor += maxTypes.1
            }
            let memberCount = try ClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
            cursor += memberCount.1
            var members: [ClickHouseArrayElementType] = []
            members.reserveCapacity(Int(memberCount.0))
            for _ in 0..<Int(memberCount.0) {
                let name = try ClickHouseWire.readString(base: base, offset: cursor, limit: limit)
                cursor += name.1
                members.append(try parseMapElementType(typeName: name.0, mapTypeName: "Dynamic"))
            }
            return DynamicPrefix(members: members, nextOffset: cursor)
        } catch let error as ClickHouseError {
            throw error
        } catch {
            throw .protocolError(stage: "decoder.parseDynamic", message: "\(error)")
        }
    }

    // Aligns ClickHouse's possibly non-contiguous discriminator values to
    // contiguous member positions. The member list is stored in ascending
    // discriminator order, so the k-th smallest distinct present
    // discriminator corresponds to member position k. NULL (255) is left
    // unchanged.
    private static func normalizeDynamicDiscriminators(_ raw: [UInt8], memberCount: Int) -> [UInt8] {
        var distinct: [UInt8] = []
        for value in raw where value != 255 && !distinct.contains(value) {
            distinct.append(value)
        }
        distinct.sort()
        var position = [UInt8](repeating: 255, count: 256)
        for index in distinct.indices where index < memberCount {
            position[Int(distinct[index])] = UInt8(index)
        }
        var normalized = [UInt8](repeating: 255, count: raw.count)
        for row in raw.indices where raw[row] != 255 {
            normalized[row] = position[Int(raw[row])]
        }
        return normalized
    }

    private static func parseArrayOfTupleColumn(
        innerTupleTypeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let elementTypes = try parseArrayOfTupleElementTypes(innerTupleTypeName: innerTupleTypeName)
        if rowCount == 0 {
            return .init(
                column: .arrayOfTuple(firstValues: [], secondValues: [], firstElement: elementTypes.first, secondElement: elementTypes.second),
                nextOffset: offset
            )
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: innerTupleTypeName)
        var cursor = offset + rowCount * 8
        let totalElements = Int(offsets[rowCount - 1])
        let flatFirst = try readArrayElements(element: elementTypes.first, count: totalElements, base: base, offset: cursor, limit: limit, typeName: innerTupleTypeName)
        cursor = flatFirst.nextOffset
        let flatSecond = try readArrayElements(element: elementTypes.second, count: totalElements, base: base, offset: cursor, limit: limit, typeName: innerTupleTypeName)
        cursor = flatSecond.nextOffset
        let perRowFirst = try groupArrayElements(flatFirst.elements, offsets: offsets, typeName: innerTupleTypeName)
        let perRowSecond = try groupArrayElements(flatSecond.elements, offsets: offsets, typeName: innerTupleTypeName)
        return .init(
            column: .arrayOfTuple(firstValues: perRowFirst, secondValues: perRowSecond, firstElement: elementTypes.first, secondElement: elementTypes.second),
            nextOffset: cursor
        )
    }

    private static func parseArrayOfTupleElementTypes(innerTupleTypeName: String) throws(ClickHouseError) -> (first: ClickHouseArrayElementType, second: ClickHouseArrayElementType) {
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: innerTupleTypeName)
        if elements.count != 2 {
            throw .protocolError(stage: "decoder.arrayOfTuple", message: "Array(Tuple) needs exactly 2 inner types, got \(elements.count) in \(innerTupleTypeName)")
        }
        let first = try parseMapElementType(typeName: elements[0].type, mapTypeName: innerTupleTypeName)
        let second = try parseMapElementType(typeName: elements[1].type, mapTypeName: innerTupleTypeName)
        return (first, second)
    }

    private static func parseMapElementTypes(typeName: String) throws(ClickHouseError) -> (key: ClickHouseArrayElementType, value: ClickHouseArrayElementType) {
        let inner = String(typeName.dropFirst("Map(".count).dropLast())
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: "Tuple(\(inner))")
        if elements.count != 2 {
            throw .protocolError(stage: "decoder.map", message: "Map needs exactly 2 inner types, got \(elements.count) in \(typeName)")
        }
        let key = try parseMapElementType(typeName: elements[0].type, mapTypeName: typeName)
        let value = try parseMapElementType(typeName: elements[1].type, mapTypeName: typeName)
        return (key, value)
    }

    private static func parseMapElementType(typeName: String, mapTypeName: String) throws(ClickHouseError) -> ClickHouseArrayElementType {
        switch typeName {
        case "String": return .string
        case "Int8": return .int8
        case "Int16": return .int16
        case "Int32": return .int32
        case "Int64": return .int64
        case "UInt8": return .uint8
        case "UInt16": return .uint16
        case "UInt32": return .uint32
        case "UInt64": return .uint64
        case "Float32": return .float32
        case "Float64": return .float64
        default:
            if typeName.hasPrefix("FixedString(") {
                return .fixedString(length: try parseFixedStringLength(typeName: typeName))
            }
            throw .protocolError(stage: "decoder.map", message: "unsupported Map element type \(typeName) in \(mapTypeName)")
        }
    }

    private static func groupArrayElements(_ flat: [[UInt8]], offsets: [UInt64], typeName: String) throws(ClickHouseError) -> [[[UInt8]]] {
        var perRow: [[[UInt8]]] = []
        perRow.reserveCapacity(offsets.count)
        var start = 0
        for offset in offsets {
            let end = Int(offset)
            if end < start || end > flat.count {
                throw .protocolError(stage: "decoder.array", message: "offset \(end) out of element range \(flat.count) in \(typeName)")
            }
            perRow.append(Array(flat[start..<end]))
            start = end
        }
        return perRow
    }

    private struct ArrayElementsResult {
        let elements: [[UInt8]]
        let nextOffset: Int
    }

    private static func readArrayElements(
        element: ClickHouseArrayElementType,
        count: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        typeName: String
    ) throws(ClickHouseError) -> ArrayElementsResult {
        let width = element.fixedWidth
        if width < 0 {
            let (strings, consumed) = try parseStringColumn(rowCount: count, base: base, offset: offset, limit: limit)
            return ArrayElementsResult(elements: strings.map { Array($0.utf8) }, nextOffset: offset + consumed)
        }
        try requireBytes(count * width, available: limit - offset, typeName: typeName)
        var elements: [[UInt8]] = []
        elements.reserveCapacity(count)
        for index in 0..<count {
            let start = offset + index * width
            var bytes = [UInt8](repeating: 0, count: width)
            bytes.withUnsafeMutableBufferPointer { destination in
                guard let target = destination.baseAddress, width > 0 else { return }
                target.update(from: base + start, count: width)
            }
            elements.append(bytes)
        }
        return ArrayElementsResult(elements: elements, nextOffset: offset + count * width)
    }

    private static func parseArrayElementType(typeName: String) throws(ClickHouseError) -> ClickHouseArrayElementType {
        let inner = String(typeName.dropFirst("Array(".count).dropLast())
        switch inner {
        case "String": return .string
        case "Int8": return .int8
        case "Int16": return .int16
        case "Int32": return .int32
        case "Int64": return .int64
        case "UInt8": return .uint8
        case "UInt16": return .uint16
        case "UInt32": return .uint32
        case "UInt64": return .uint64
        case "Float32": return .float32
        case "Float64": return .float64
        default:
            if inner.hasPrefix("FixedString(") {
                return .fixedString(length: try parseFixedStringLength(typeName: inner))
            }
            throw .protocolError(stage: "decoder.array", message: "unsupported Array element type \(inner)")
        }
    }

    private static func parseLowCardinalityColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let inner = try parseLowCardinalityInner(typeName: typeName)
        if rowCount == 0 {
            return .init(column: .lowCardinality([], inner: inner), nextOffset: offset)
        }
        var cursor = offset
        _ = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
        cursor += 8
        let serializationType = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
        cursor += 8
        let width = lowCardinalityKeyWidth(serializationType: serializationType)
        let dictionarySize = Int(try readUInt64Scalar(base: base, offset: cursor, limit: limit))
        cursor += 8
        let dictionaryResult = try readLowCardinalityDictionary(inner: inner, dictionarySize: dictionarySize, base: base, offset: cursor, limit: limit)
        cursor = dictionaryResult.nextOffset
        let indicesCount = Int(try readUInt64Scalar(base: base, offset: cursor, limit: limit))
        cursor += 8
        let perRow = try readLowCardinalityIndices(count: indicesCount, width: width, dictionary: dictionaryResult.dictionary, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor += indicesCount * width
        return .init(column: .lowCardinality(perRow, inner: inner), nextOffset: cursor)
    }

    private static func readUInt64Scalar(base: UnsafePointer<UInt8>, offset: Int, limit: Int) throws(ClickHouseError) -> UInt64 {
        let values: [UInt64] = try parseFixedWidth(rowCount: 1, base: base, offset: offset, limit: limit, typeName: "LowCardinality")
        return values[0]
    }

    private static func lowCardinalityKeyWidth(serializationType: UInt64) -> Int {
        switch serializationType & 0xFF {
        case 0: return 1
        case 1: return 2
        case 2: return 4
        default: return 8
        }
    }

    private struct LowCardinalityDictionaryResult {
        let dictionary: [[UInt8]]
        let nextOffset: Int
    }

    private static func readLowCardinalityDictionary(
        inner: ClickHouseLowCardinalityInner,
        dictionarySize: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> LowCardinalityDictionaryResult {
        switch inner {
        case .string:
            let (strings, consumed) = try parseStringColumn(rowCount: dictionarySize, base: base, offset: offset, limit: limit)
            return LowCardinalityDictionaryResult(dictionary: strings.map { Array($0.utf8) }, nextOffset: offset + consumed)
        case .fixedString(let length):
            return try readLowCardinalityFixedDictionary(dictionarySize: dictionarySize, length: length, base: base, offset: offset, limit: limit)
        }
    }

    private static func readLowCardinalityFixedDictionary(
        dictionarySize: Int,
        length: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> LowCardinalityDictionaryResult {
        try requireBytes(dictionarySize * length, available: limit - offset, typeName: "LowCardinality(FixedString)")
        var dictionary: [[UInt8]] = []
        dictionary.reserveCapacity(dictionarySize)
        for index in 0..<dictionarySize {
            let start = offset + index * length
            var bytes = [UInt8](repeating: 0, count: length)
            bytes.withUnsafeMutableBufferPointer { destination in
                guard let target = destination.baseAddress, length > 0 else { return }
                target.update(from: base + start, count: length)
            }
            dictionary.append(bytes)
        }
        return LowCardinalityDictionaryResult(dictionary: dictionary, nextOffset: offset + dictionarySize * length)
    }

    private static func readLowCardinalityIndices(
        count: Int,
        width: Int,
        dictionary: [[UInt8]],
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        typeName: String
    ) throws(ClickHouseError) -> [[UInt8]] {
        try requireBytes(count * width, available: limit - offset, typeName: typeName)
        var perRow: [[UInt8]] = []
        perRow.reserveCapacity(count)
        for index in 0..<count {
            let dictionaryIndex = readLittleEndianIndex(base: base, offset: offset + index * width, width: width)
            if dictionaryIndex < 0 || dictionaryIndex >= dictionary.count {
                throw .protocolError(stage: "decoder.lowCardinality", message: "index \(dictionaryIndex) out of dictionary range \(dictionary.count) in \(typeName)")
            }
            perRow.append(dictionary[dictionaryIndex])
        }
        return perRow
    }

    private static func readLittleEndianIndex(base: UnsafePointer<UInt8>, offset: Int, width: Int) -> Int {
        var value: UInt64 = 0
        for byteIndex in 0..<width {
            value |= UInt64(base[offset + byteIndex]) << (8 * byteIndex)
        }
        return Int(truncatingIfNeeded: value)
    }

    private static func parseLowCardinalityInner(typeName: String) throws(ClickHouseError) -> ClickHouseLowCardinalityInner {
        let inner = String(typeName.dropFirst("LowCardinality(".count).dropLast())
        if inner == "String" {
            return .string
        }
        if inner.hasPrefix("FixedString(") {
            return .fixedString(length: try parseFixedStringLength(typeName: inner))
        }
        throw .protocolError(stage: "decoder.lowCardinality", message: "unsupported LowCardinality inner type \(inner)")
    }

    private static func parseEnum8Column(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let mapping = try parseEnumMapping(typeName: typeName, prefixCount: "Enum8(".utf8.count)
        try requireBytes(rowCount, available: limit - offset, typeName: typeName)
        var values = [Int8]()
        values.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            values.append(Int8(bitPattern: base[offset + index]))
        }
        return .init(column: .enum8(values, mapping: mapping), nextOffset: offset + rowCount)
    }

    private static func parseEnum16Column(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let mapping = try parseEnumMapping(typeName: typeName, prefixCount: "Enum16(".utf8.count)
        let values: [Int16] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        return .init(column: .enum16(values, mapping: mapping), nextOffset: offset + rowCount * 2)
    }

    private static func parseEnumMapping(typeName: String, prefixCount: Int) throws(ClickHouseError) -> [ClickHouseEnumPair] {
        let bytes = Array(typeName.utf8)
        var cursor = prefixCount
        var pairs: [ClickHouseEnumPair] = []
        while cursor < bytes.count {
            cursor = skipEnumSeparators(bytes, from: cursor)
            if cursor >= bytes.count || bytes[cursor] == 0x29 { break }
            let nameResult = try readEnumName(bytes, from: cursor, typeName: typeName)
            let valueResult = try readEnumValue(bytes, from: nameResult.nextOffset, typeName: typeName)
            pairs.append(ClickHouseEnumPair(name: nameResult.name, value: valueResult.value))
            cursor = valueResult.nextOffset
        }
        if pairs.isEmpty {
            throw .protocolError(stage: "decoder.enum", message: "empty enum mapping in \(typeName)")
        }
        return pairs
    }

    private static func skipEnumSeparators(_ bytes: [UInt8], from offset: Int) -> Int {
        var cursor = offset
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x2c {
            cursor += 1
        }
        return cursor
    }

    private struct EnumNameResult {
        let name: String
        let nextOffset: Int
    }

    private static func readEnumName(_ bytes: [UInt8], from offset: Int, typeName: String) throws(ClickHouseError) -> EnumNameResult {
        if offset >= bytes.count || bytes[offset] != 0x27 {
            throw .protocolError(stage: "decoder.enum", message: "expected quoted name in \(typeName)")
        }
        var cursor = offset + 1
        var nameBytes: [UInt8] = []
        while cursor < bytes.count, bytes[cursor] != 0x27 {
            nameBytes.append(bytes[cursor])
            cursor += 1
        }
        if cursor >= bytes.count {
            throw .protocolError(stage: "decoder.enum", message: "unterminated name in \(typeName)")
        }
        return EnumNameResult(name: String(decoding: nameBytes, as: UTF8.self), nextOffset: cursor + 1)
    }

    private struct EnumValueResult {
        let value: Int16
        let nextOffset: Int
    }

    private static func readEnumValue(_ bytes: [UInt8], from offset: Int, typeName: String) throws(ClickHouseError) -> EnumValueResult {
        var cursor = skipEnumValuePrefix(bytes, from: offset)
        var negative = false
        if cursor < bytes.count, bytes[cursor] == 0x2d {
            negative = true
            cursor += 1
        }
        var magnitude = 0
        var digitCount = 0
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            if magnitude <= 1_000_000 { magnitude = magnitude * 10 + Int(bytes[cursor] - 0x30) }
            digitCount += 1
            cursor += 1
        }
        let signed = negative ? -magnitude : magnitude
        try requireEnumValueInRange(digitCount: digitCount, signed: signed, typeName: typeName)
        return EnumValueResult(value: Int16(signed), nextOffset: cursor)
    }

    private static func skipEnumValuePrefix(_ bytes: [UInt8], from offset: Int) -> Int {
        var cursor = offset
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x3d {
            cursor += 1
        }
        return cursor
    }

    private static func requireEnumValueInRange(digitCount: Int, signed: Int, typeName: String) throws(ClickHouseError) {
        if digitCount == 0 {
            throw .protocolError(stage: "decoder.enum", message: "missing enum value in \(typeName)")
        }
        if signed < Int(Int16.min) || signed > Int(Int16.max) {
            throw .protocolError(stage: "decoder.enum", message: "enum value out of Int16 range in \(typeName)")
        }
    }

    private static func parseFixedStringColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let length = try parseFixedStringLength(typeName: typeName)
        try requireBytes(rowCount * length, available: limit - offset, typeName: typeName)
        var values: [[UInt8]] = []
        values.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let start = offset + index * length
            var bytes = [UInt8](repeating: 0, count: length)
            bytes.withUnsafeMutableBufferPointer { destination in
                guard let target = destination.baseAddress, length > 0 else { return }
                target.update(from: base + start, count: length)
            }
            values.append(bytes)
        }
        return .init(column: .fixedString(values, length: length), nextOffset: offset + rowCount * length)
    }

    private static func parseFixedStringLength(typeName: String) throws(ClickHouseError) -> Int {
        let inner = typeName.dropFirst("FixedString(".count)
        var value = 0
        var digitCount = 0
        for byte in inner.utf8 {
            if byte < 0x30 || byte > 0x39 { break }
            value = value * 10 + Int(byte - 0x30)
            digitCount += 1
            if value > 1_000_000 {
                throw .protocolError(stage: "decoder.fixedString", message: "length out of range in \(typeName)")
            }
        }
        if digitCount == 0 {
            throw .protocolError(stage: "decoder.fixedString", message: "missing length in \(typeName)")
        }
        return value
    }

    private static func parseDateTime64Precision(typeName: String) throws(ClickHouseError) -> UInt8 {
        try parseParenthesizedPrecision(typeName: typeName, prefix: "DateTime64(", stage: "decoder.dateTime64")
    }

    private static func parseParenthesizedPrecision(typeName: String, prefix: String, stage: String) throws(ClickHouseError) -> UInt8 {
        let inner = typeName.dropFirst(prefix.count)
        var value = 0
        var digitCount = 0
        for byte in inner.utf8 {
            if byte < 0x30 || byte > 0x39 { break }
            value = value * 10 + Int(byte - 0x30)
            digitCount += 1
            if value > 255 {
                throw .protocolError(stage: stage, message: "precision out of range in \(typeName)")
            }
        }
        if digitCount == 0 {
            throw .protocolError(stage: stage, message: "missing precision in \(typeName)")
        }
        return UInt8(value)
    }

    private static func parseDecimalColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let parameters = try parseDecimalParameters(typeName: typeName)
        let width = ClickHouseDecimalWidth.bytes(forPrecision: parameters.precision)
        try requireBytes(rowCount * width, available: limit - offset, typeName: typeName)
        var values: [ClickHouseDecimal] = []
        values.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let start = offset + index * width
            let limbs = decimalLimbs(base: base, offset: start, width: width)
            values.append(ClickHouseDecimal(
                limb0: limbs.0,
                limb1: limbs.1,
                limb2: limbs.2,
                limb3: limbs.3,
                precision: parameters.precision,
                scale: parameters.scale
            ))
        }
        return .init(column: .decimal(values, precision: parameters.precision, scale: parameters.scale), nextOffset: offset + rowCount * width)
    }

    @inline(__always)
    private static func read256Limbs(base: UnsafePointer<UInt8>, offset: Int) -> (UInt64, UInt64, UInt64, UInt64) {
        var limbs: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        withUnsafeMutableBytes(of: &limbs) { raw in
            raw.baseAddress?.copyMemory(from: base + offset, byteCount: 32)
        }
        return (UInt64(littleEndian: limbs.0), UInt64(littleEndian: limbs.1), UInt64(littleEndian: limbs.2), UInt64(littleEndian: limbs.3))
    }

    @inline(__always)
    private static func decimalLimbs(base: UnsafePointer<UInt8>, offset: Int, width: Int) -> (UInt64, UInt64, UInt64, UInt64) {
        let signByte = base[offset + width - 1]
        let extension64: UInt64 = signByte & 0x80 != 0 ? .max : 0
        var limbs: (UInt64, UInt64, UInt64, UInt64) = (extension64, extension64, extension64, extension64)
        withUnsafeMutableBytes(of: &limbs) { raw in
            raw.baseAddress?.copyMemory(from: base + offset, byteCount: width)
        }
        return (UInt64(littleEndian: limbs.0), UInt64(littleEndian: limbs.1), UInt64(littleEndian: limbs.2), UInt64(littleEndian: limbs.3))
    }

    private static func parseDecimalParameters(typeName: String) throws(ClickHouseError) -> (precision: UInt8, scale: UInt8) {
        if typeName.hasPrefix("Decimal(") {
            return try parseDecimalAlias(typeName: typeName)
        }
        if typeName.hasPrefix("Decimal32(") {
            return (9, try parseSingleDecimalScale(typeName: typeName, prefix: "Decimal32("))
        }
        if typeName.hasPrefix("Decimal64(") {
            return (18, try parseSingleDecimalScale(typeName: typeName, prefix: "Decimal64("))
        }
        if typeName.hasPrefix("Decimal128(") {
            return (38, try parseSingleDecimalScale(typeName: typeName, prefix: "Decimal128("))
        }
        if typeName.hasPrefix("Decimal256(") {
            return (76, try parseSingleDecimalScale(typeName: typeName, prefix: "Decimal256("))
        }
        throw .protocolError(stage: "decoder.decimal", message: "unrecognized Decimal type \(typeName)")
    }

    private static func parseDecimalAlias(typeName: String) throws(ClickHouseError) -> (precision: UInt8, scale: UInt8) {
        let inner = Substring(typeName.dropFirst("Decimal(".count))
        let precisionScan = scanDecimalInteger(inner)
        if precisionScan.digitCount == 0 {
            throw .protocolError(stage: "decoder.decimal", message: "missing precision in \(typeName)")
        }
        if precisionScan.value > 76 {
            throw .protocolError(stage: "decoder.decimal", message: "precision out of range in \(typeName)")
        }
        var rest = inner.dropFirst(precisionScan.digitCount)
        while rest.first == " " || rest.first == "," { rest = rest.dropFirst() }
        let scaleScan = scanDecimalInteger(rest)
        if scaleScan.digitCount == 0 {
            throw .protocolError(stage: "decoder.decimal", message: "missing scale in \(typeName)")
        }
        return (UInt8(precisionScan.value), UInt8(scaleScan.value))
    }

    private static func parseSingleDecimalScale(typeName: String, prefix: String) throws(ClickHouseError) -> UInt8 {
        let inner = Substring(typeName.dropFirst(prefix.count))
        let scan = scanDecimalInteger(inner)
        if scan.digitCount == 0 {
            throw .protocolError(stage: "decoder.decimal", message: "missing scale in \(typeName)")
        }
        return UInt8(scan.value)
    }

    private static func scanDecimalInteger(_ text: Substring) -> (value: Int, digitCount: Int) {
        var value = 0
        var digitCount = 0
        for byte in text.utf8 {
            if byte < 0x30 || byte > 0x39 { break }
            value = value * 10 + Int(byte - 0x30)
            digitCount += 1
            if value > 1_000_000 { break }
        }
        return (value, digitCount)
    }

    private static func parseNullableColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
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
        inner: ClickHouseTypedColumn
    ) throws(ClickHouseError) -> ClickHouseTypedColumn {
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
            return .nullable(mask: maskBools(mask), inner: inner)
        }
    }

    private static func maskBools(_ mask: UnsafeBufferPointer<UInt8>) -> [Bool] {
        var result = [Bool](); result.reserveCapacity(mask.count)
        for index in 0..<mask.count { result.append(mask[index] != 0) }
        return result
    }

    private static func mergeMask<T: Sendable>(_ mask: UnsafeBufferPointer<UInt8>, values: [T]) -> [ClickHouseNullable<T>] {
        var result = [ClickHouseNullable<T>](); result.reserveCapacity(values.count)
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
    ) throws(ClickHouseError) -> ([String], Int) {
        var values: [String] = []
        values.reserveCapacity(rowCount)
        var cursor = offset
        for _ in 0..<rowCount {
            do {
                let parsed = try ClickHouseWire.readString(base: base, offset: cursor, limit: limit)
                values.append(parsed.0)
                cursor += parsed.1
            } catch {
                throw .protocolError(stage: "decoder.parseStringColumn", message: "\(error)")
            }
        }
        return (values, cursor - offset)
    }

    // AggregateFunction column body is the per-row serialized states
    // concatenated with no framing. Each state is delimited only when its
    // width is constant and known from the signature; the width table in
    // `ClickHouseAggregateStateWidth` throws for signatures SwiftDX cannot
    // decode so we never mis-slice an unframed body.
    private static func parseAggregateFunctionColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let signature = String(typeName.dropFirst("AggregateFunction(".count).dropLast())
        if rowCount == 0 {
            return .init(column: .aggregateFunction(signature: signature, states: []), nextOffset: offset)
        }
        let width = try ClickHouseAggregateStateWidth.width(signature: signature)
        let total = rowCount * width
        try requireBytes(total, available: limit - offset, typeName: typeName)
        var states: [[UInt8]] = []
        states.reserveCapacity(rowCount)
        var cursor = offset
        for _ in 0..<rowCount {
            states.append(Array(UnsafeBufferPointer(start: base + cursor, count: width)))
            cursor += width
        }
        return .init(column: .aggregateFunction(signature: signature, states: states), nextOffset: cursor)
    }

    private static func parseFixedWidth<T: FixedWidthInteger>(
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        typeName: String
    ) throws(ClickHouseError) -> [T] {
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
        // Inverse of `ClickHouseBlockWriter.appendUUID`: swap each
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

    private static func requireBytes(_ needed: Int, available: Int, typeName: String) throws(ClickHouseError) {
        if available < needed {
            throw .protocolError(stage: "decoder.requireBytes", message: "column \(typeName) needs \(needed) bytes, \(available) available")
        }
    }
}
