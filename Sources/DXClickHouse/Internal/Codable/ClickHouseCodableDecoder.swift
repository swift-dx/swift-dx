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
package enum ClickHouseCodableDecoder {

    package static func parseTypedColumns(
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

    package static func decodeRows<T: Decodable>(
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

    // Columnar fast path: bind the destination columns by name once, then
    // build each row through the ClickHouseFastRow cursor with no per-row
    // container allocation. Orders of magnitude faster than the Codable path
    // for large result sets.
    package static func decodeFastRows<T: ClickHouseRowDecodable>(
        type: T.Type,
        columns: [ClickHouseNamedColumn],
        rowCount: Int
    ) throws(ClickHouseError) -> [T] {
        if rowCount == 0 { return [] }
        let bound = try bindFastColumns(T.clickHouseColumnNames, to: columns)
        return try T.decodeBlock(ClickHouseColumnBlock(columns: bound, count: rowCount))
    }

    private static func bindFastColumns(
        _ names: [String],
        to columns: [ClickHouseNamedColumn]
    ) throws(ClickHouseError) -> [ClickHouseTypedColumn] {
        var index: [String: ClickHouseTypedColumn] = [:]
        index.reserveCapacity(columns.count)
        for column in columns { index[column.name] = column.column }
        var bound: [ClickHouseTypedColumn] = []
        bound.reserveCapacity(names.count)
        for name in names {
            guard let column = index[name] else {
                throw .protocolError(stage: "decoder.fastRow", message: "result has no column named '\(name)'")
            }
            bound.append(column)
        }
        return bound
    }

    // Fused fast path: parse the block body in one pass into direct byte
    // views (fixed-width base offsets, String byte ranges) and hand them to
    // the type's decodeFused. No intermediate typed-column arrays and no
    // per-string allocation.
    package static func decodeFusedRows<T: ClickHouseFusedDecodable>(
        type: T.Type,
        block: ClickHouseBlock,
        body: UnsafeRawBufferPointer
    ) throws(ClickHouseError) -> [T] {
        if block.rowCount == 0 { return [] }
        guard let base = body.baseAddress else {
            throw .protocolError(stage: "decoder.raw", message: "block body is empty")
        }
        let bytePtr = base.assumingMemoryBound(to: UInt8.self)
        let rowCount = block.rowCount
        let limit = body.count
        var blockBaseOffset = [Int](repeating: 0, count: block.columnCount)
        var columnSpanBase = [Int](repeating: -1, count: block.columnCount)
        var stringSpans = [Int]()
        var offset = 0
        for column in 0..<block.columnCount {
            let width = fixedElementWidth(block.columnTypes[column])
            if width >= 0 {
                blockBaseOffset[column] = offset
                offset += rowCount * width
            } else if block.columnTypes[column] == "String" {
                columnSpanBase[column] = stringSpans.count
                stringSpans.reserveCapacity(stringSpans.count + rowCount * 2)
                for _ in 0..<rowCount {
                    let parsed: (UInt64, Int)
                    do {
                        parsed = try ClickHouseWire.readUVarInt(base: bytePtr, offset: offset, limit: limit)
                    } catch {
                        throw .protocolError(stage: "decoder.raw", message: "malformed String length")
                    }
                    let dataStart = offset + parsed.1
                    let dataEnd = dataStart + Int(parsed.0)
                    if dataEnd > limit { throw .protocolError(stage: "decoder.raw", message: "String body overruns block") }
                    stringSpans.append(dataStart)
                    stringSpans.append(Int(parsed.0))
                    offset = dataEnd
                }
            } else {
                throw .protocolError(stage: "decoder.raw", message: "fused path does not support column type \(block.columnTypes[column])")
            }
        }
        var nameToColumn: [String: Int] = [:]
        nameToColumn.reserveCapacity(block.columnCount)
        for column in 0..<block.columnCount { nameToColumn[block.columnNames[column]] = column }
        var fieldBaseOffset: [Int] = []
        var fieldStringBase: [Int] = []
        for name in T.clickHouseColumnNames {
            guard let column = nameToColumn[name] else {
                throw .protocolError(stage: "decoder.raw", message: "result has no column named '\(name)'")
            }
            fieldBaseOffset.append(blockBaseOffset[column])
            fieldStringBase.append(columnSpanBase[column])
        }
        let raw = ClickHouseRawBlock(
            base: base,
            columnBaseOffset: fieldBaseOffset,
            stringSpans: stringSpans,
            stringFieldBase: fieldStringBase,
            count: rowCount
        )
        return try T.decodeFused(raw)
    }

    // The on-wire element width of a fixed-width column type, or -1 for a
    // variable-width (String) or non-fixed (Array/Nullable/Map/...) type. The
    // fused parser uses this to size every column in the block so it can find
    // the byte offset of the columns it decodes, even when the result contains
    // other fixed-width columns (DateTime, UUID, Decimal, an unrequested
    // column) it does not itself materialise.
    private static func fixedElementWidth(_ typeName: String) -> Int {
        switch typeName {
        case "UInt8", "Int8", "Bool", "Enum8": 1
        case "UInt16", "Int16", "Date": 2
        case "UInt32", "Int32", "Float32", "DateTime", "Date32", "IPv4", "Enum16": 4
        case "UInt64", "Int64", "Float64", "DateTime64": 8
        case "UInt128", "Int128", "UUID", "IPv6", "Decimal128": 16
        case "UInt256", "Int256", "Decimal256": 32
        case "Decimal32": 4
        case "Decimal64": 8
        default: parameterizedFixedWidth(typeName)
        }
    }

    private static func parameterizedFixedWidth(_ typeName: String) -> Int {
        if typeName.hasPrefix("Enum8(") { return 1 }
        if typeName.hasPrefix("Enum16(") { return 2 }
        if typeName.hasPrefix("DateTime64(") { return 8 }
        if typeName.hasPrefix("DateTime(") { return 4 }
        if typeName.hasPrefix("Decimal32(") { return 4 }
        if typeName.hasPrefix("Decimal64(") { return 8 }
        if typeName.hasPrefix("Decimal128(") { return 16 }
        if typeName.hasPrefix("Decimal256(") { return 32 }
        if typeName.hasPrefix("FixedString(") {
            return Int(typeName.dropFirst("FixedString(".count).dropLast()) ?? -1
        }
        if typeName.hasPrefix("Decimal(") {
            return decimalWidthFromParameters(typeName)
        }
        return -1
    }

    private static func decimalWidthFromParameters(_ typeName: String) -> Int {
        let inner = typeName.dropFirst("Decimal(".count).dropLast()
        let firstField = inner.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let precision = UInt8(firstField) else { return -1 }
        return ClickHouseDecimalWidth.bytes(forPrecision: precision)
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
        if inner.hasPrefix("Nullable(") {
            return try parseArrayOfNullableColumn(arrayTypeName: typeName, innerNullable: inner, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        if inner.hasPrefix("Array(") {
            return try parseNestedArrayColumn(arrayTypeName: typeName, innerArrayTypeName: inner, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        if inner.hasPrefix("LowCardinality(") {
            return try parseArrayOfLowCardinalityColumn(arrayTypeName: typeName, innerLowCardinality: inner, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        let element = try parseArrayElementType(typeName: typeName)
        if rowCount == 0 {
            return .init(column: .array([], element: element), nextOffset: offset)
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        var cursor = offset + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: typeName, stage: "decoder.array")
        let flat = try readArrayElements(element: element, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flat.nextOffset
        let perRow = try groupArrayElements(flat.elements, offsets: offsets, typeName: typeName)
        return .init(column: .array(perRow, element: element), nextOffset: cursor)
    }

    // Array(Nullable(T)) on the wire: rowCount cumulative offsets, then the
    // flattened inner column as a Nullable(T) — a totalElements-byte null mask
    // (1 = NULL) followed by totalElements inner-T values (NULL slots still
    // carry a placeholder value). We lift the mask onto the values and group
    // by the offsets so the decoder yields per-row arrays of nullable
    // elements.
    private static func parseArrayOfNullableColumn(
        arrayTypeName: String,
        innerNullable: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let innerType = String(innerNullable.dropFirst("Nullable(".count).dropLast())
        let element = try parseArrayElementType(typeName: "Array(\(innerType))")
        if rowCount == 0 {
            return .init(column: .arrayOfNullable(perRow: [], element: element), nextOffset: offset)
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: arrayTypeName)
        var cursor = offset + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: arrayTypeName, stage: "decoder.arrayOfNullable")
        try requireBytes(totalElements, available: limit - cursor, typeName: arrayTypeName)
        var mask: [Bool] = []
        mask.reserveCapacity(totalElements)
        for index in 0..<totalElements { mask.append(base[cursor + index] != 0) }
        cursor += totalElements
        let flat = try readArrayElements(element: element, count: totalElements, base: base, offset: cursor, limit: limit, typeName: arrayTypeName)
        cursor = flat.nextOffset
        var combined: [ClickHouseNullable<[UInt8]>] = []
        combined.reserveCapacity(totalElements)
        for index in 0..<totalElements {
            combined.append(mask[index] ? .absent : .present(flat.elements[index]))
        }
        let perRow = try groupByOffsets(combined, offsets: offsets, stage: "decoder.arrayOfNullable", typeName: arrayTypeName)
        return .init(column: .arrayOfNullable(perRow: perRow, element: element), nextOffset: cursor)
    }

    // Array(LowCardinality(String)) / Array(LowCardinality(FixedString(N))) on the
    // wire: rowCount cumulative offsets, then the flattened inner values as a
    // single LowCardinality sub-column (its own version prefix, dictionary, and
    // one key per element). We resolve each key through the dictionary and group
    // by the offsets, yielding per-row arrays whose element type mirrors the
    // dictionary's so a FixedString element trims its padding like a plain
    // Array(FixedString) and a String element reads verbatim.
    private static func parseArrayOfLowCardinalityColumn(
        arrayTypeName: String,
        innerLowCardinality: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let inner = try parseLowCardinalityInner(typeName: innerLowCardinality)
        let element = arrayElementType(forLowCardinalityInner: inner)
        if rowCount == 0 {
            return .init(column: .array([], element: element), nextOffset: offset)
        }
        _ = try readUInt64Scalar(base: base, offset: offset, limit: limit)
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset + 8, limit: limit, typeName: arrayTypeName)
        let cursor = offset + 8 + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: arrayTypeName, stage: "decoder.array")
        return try resolveArrayLowCardinality(offsets: offsets, totalElements: totalElements, rowCount: rowCount, inner: inner, element: element, arrayTypeName: arrayTypeName, base: base, offset: cursor, limit: limit)
    }

    private static func arrayElementType(forLowCardinalityInner inner: ClickHouseLowCardinalityInner) -> ClickHouseArrayElementType {
        switch inner {
        case .string: .string
        case .fixedString(let length): .fixedString(length: length)
        }
    }

    // An all-empty Array(LowCardinality) column (totalElements == 0) stops after
    // the hoisted version and the offsets — the dictionary bulk is omitted — so
    // every row is an empty array. Otherwise the dictionary bulk follows and each
    // key resolves through it before grouping by the offsets.
    private static func resolveArrayLowCardinality(
        offsets: [UInt64],
        totalElements: Int,
        rowCount: Int,
        inner: ClickHouseLowCardinalityInner,
        element: ClickHouseArrayElementType,
        arrayTypeName: String,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        guard totalElements > 0 else {
            return .init(column: .array([[[UInt8]]](repeating: [], count: rowCount), element: element), nextOffset: offset)
        }
        let structure = try readLowCardinalityBulk(inner: inner, typeName: arrayTypeName, base: base, offset: offset, limit: limit)
        guard structure.indices.count == totalElements else {
            throw .protocolError(stage: "decoder.array", message: "low-cardinality index count \(structure.indices.count) does not match array element count \(totalElements) in \(arrayTypeName)")
        }
        let elements = structure.indices.map { structure.dictionary[$0] }
        let perRow = try groupByOffsets(elements, offsets: offsets, stage: "decoder.array", typeName: arrayTypeName)
        return .init(column: .array(perRow, element: element), nextOffset: structure.nextOffset)
    }

    // Array(Array(T)) on the wire: rowCount outer offsets, then totalOuter
    // inner offsets, then the flattened innermost T elements. We group the
    // elements by the inner offsets into inner arrays, then group the inner
    // arrays by the outer offsets into per-row [[T]]. Only one level of
    // nesting (the innermost element must be a scalar element type);
    // Array(Array(Array(T))) falls back to the unsupported-element rejection.
    private static func parseNestedArrayColumn(
        arrayTypeName: String,
        innerArrayTypeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let element = try parseArrayElementType(typeName: innerArrayTypeName)
        if rowCount == 0 {
            return .init(column: .nestedArray(perRow: [], element: element), nextOffset: offset)
        }
        let outerOffsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: arrayTypeName)
        var cursor = offset + rowCount * 8
        let totalOuter = try boundedElementCount(outerOffsets[rowCount - 1], available: limit - cursor, typeName: arrayTypeName, stage: "decoder.nestedArray")
        let innerOffsets: [UInt64] = try parseFixedWidth(rowCount: totalOuter, base: base, offset: cursor, limit: limit, typeName: arrayTypeName)
        cursor += totalOuter * 8
        var totalInner = 0
        if totalOuter > 0 {
            totalInner = try boundedElementCount(innerOffsets[totalOuter - 1], available: limit - cursor, typeName: arrayTypeName, stage: "decoder.nestedArray")
        }
        let flat = try readArrayElements(element: element, count: totalInner, base: base, offset: cursor, limit: limit, typeName: arrayTypeName)
        cursor = flat.nextOffset
        let innerArrays = try groupByOffsets(flat.elements, offsets: innerOffsets, stage: "decoder.nestedArray", typeName: arrayTypeName)
        let perRow = try groupByOffsets(innerArrays, offsets: outerOffsets, stage: "decoder.nestedArray", typeName: arrayTypeName)
        return .init(column: .nestedArray(perRow: perRow, element: element), nextOffset: cursor)
    }

    private static func groupByOffsets<Element>(_ flat: [Element], offsets: [UInt64], stage: String, typeName: String) throws(ClickHouseError) -> [[Element]] {
        var perRow: [[Element]] = []
        perRow.reserveCapacity(offsets.count)
        var start = 0
        for offset in offsets {
            guard let end = Int(exactly: offset) else {
                throw .protocolError(stage: stage, message: "offset \(offset) exceeds Int range in \(typeName)")
            }
            if end < start || end > flat.count {
                throw .protocolError(stage: stage, message: "offset \(end) out of element range \(flat.count) in \(typeName)")
            }
            perRow.append(Array(flat[start..<end]))
            start = end
        }
        return perRow
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
        let (keyTypeName, valueTypeName) = try mapKeyValueTypeNames(typeName: typeName)
        if valueTypeName.hasPrefix("Nullable(") {
            return try parseMapWithNullableValuesColumn(typeName: typeName, keyTypeName: keyTypeName, valueTypeName: valueTypeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        if valueTypeName.hasPrefix("Array(") {
            return try parseMapWithArrayValuesColumn(typeName: typeName, keyTypeName: keyTypeName, valueTypeName: valueTypeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        if keyTypeName.hasPrefix("LowCardinality(") || valueTypeName.hasPrefix("LowCardinality(") {
            return try parseMapWithLowCardinalitySidesColumn(typeName: typeName, keyTypeName: keyTypeName, valueTypeName: valueTypeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        let elementTypes = try parseMapElementTypes(typeName: typeName)
        if rowCount == 0 {
            return .init(
                column: .map(keys: [], values: [], keyElement: elementTypes.key, valueElement: elementTypes.value),
                nextOffset: offset
            )
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        var cursor = offset + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: typeName, stage: "decoder.map")
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

    private static func mapKeyValueTypeNames(typeName: String) throws(ClickHouseError) -> (key: String, value: String) {
        let inner = String(typeName.dropFirst("Map(".count).dropLast())
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: "Tuple(\(inner))")
        if elements.count != 2 {
            throw .protocolError(stage: "decoder.map", message: "Map needs exactly 2 inner types, got \(elements.count) in \(typeName)")
        }
        return (elements[0].type, elements[1].type)
    }

    // Map(K, Nullable(V)): rowCount cumulative offsets, then the flattened keys
    // (a K column), then the flattened values as a Nullable(V) column — a
    // totalElements null mask followed by totalElements V values. We lift the
    // mask onto the values and group keys and values by the offsets so each
    // row becomes a [K: V?] map.
    private static func parseMapWithNullableValuesColumn(
        typeName: String,
        keyTypeName: String,
        valueTypeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let keyElement = try parseMapElementType(typeName: keyTypeName, mapTypeName: typeName)
        let innerValueType = String(valueTypeName.dropFirst("Nullable(".count).dropLast())
        let valueElement = try parseMapElementType(typeName: innerValueType, mapTypeName: typeName)
        if rowCount == 0 {
            return .init(column: .mapWithNullableValues(keys: [], values: [], keyElement: keyElement, valueElement: valueElement), nextOffset: offset)
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: typeName)
        var cursor = offset + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: typeName, stage: "decoder.map")
        let flatKeys = try readArrayElements(element: keyElement, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flatKeys.nextOffset
        try requireBytes(totalElements, available: limit - cursor, typeName: typeName)
        var mask: [Bool] = []
        mask.reserveCapacity(totalElements)
        for index in 0..<totalElements { mask.append(base[cursor + index] != 0) }
        cursor += totalElements
        let flatValues = try readArrayElements(element: valueElement, count: totalElements, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor = flatValues.nextOffset
        var combinedValues: [ClickHouseNullable<[UInt8]>] = []
        combinedValues.reserveCapacity(totalElements)
        for index in 0..<totalElements {
            combinedValues.append(mask[index] ? .absent : .present(flatValues.elements[index]))
        }
        let perRowKeys = try groupByOffsets(flatKeys.elements, offsets: offsets, stage: "decoder.map", typeName: typeName)
        let perRowValues = try groupByOffsets(combinedValues, offsets: offsets, stage: "decoder.map", typeName: typeName)
        return .init(column: .mapWithNullableValues(keys: perRowKeys, values: perRowValues, keyElement: keyElement, valueElement: valueElement), nextOffset: cursor)
    }

    // Map(K, Array(V)): a LowCardinality key hoists its serialization version
    // ahead of the map offsets (the value being Array is never a direct
    // LowCardinality side, so only the key hoists), then rowCount cumulative
    // entry offsets, then the keys (a LowCardinality dictionary bulk or a flat K
    // column over totalEntries), then the values as an Array(V) column over the
    // same totalEntries — its own per-entry offsets and flattened elements. The
    // key side and the value sub-column are read by the shared LowCardinality and
    // array parsers and regrouped from per-entry back to per-row by the outer map
    // offsets, so each row yields its keys paired with their element arrays. A
    // LowCardinality array element (Array(LowCardinality(V))) hoists its own
    // version differently and is rejected here before any bytes are read rather
    // than mis-framed; parseMapElementType throws for the LowCardinality inner.
    private static func parseMapWithArrayValuesColumn(
        typeName: String,
        keyTypeName: String,
        valueTypeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let keyElement = try mapSideElementType(typeName: keyTypeName, mapTypeName: typeName)
        let innerValueType = String(valueTypeName.dropFirst("Array(".count).dropLast())
        let valueElement = try parseMapElementType(typeName: innerValueType, mapTypeName: typeName)
        if rowCount == 0 {
            return .init(column: .mapWithArrayValues(keys: [], values: [], keyElement: keyElement, valueElement: valueElement), nextOffset: offset)
        }
        var cursor = offset
        if keyTypeName.hasPrefix("LowCardinality(") {
            _ = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
            cursor += 8
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor += rowCount * 8
        let totalEntries = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: typeName, stage: "decoder.map")
        let keySide = try readMapSideElements(typeName: keyTypeName, totalElements: totalEntries, base: base, offset: cursor, limit: limit, mapTypeName: typeName)
        cursor = keySide.nextOffset
        let valueColumn = try parseArrayColumn(typeName: valueTypeName, rowCount: totalEntries, base: base, offset: cursor, limit: limit)
        cursor = valueColumn.nextOffset
        guard case .array(let perEntryValues, _) = valueColumn.column else {
            throw .protocolError(stage: "decoder.map", message: "Map value column \(valueTypeName) did not decode as an array in \(typeName)")
        }
        let perRowKeys = try groupArrayElements(keySide.elements, offsets: offsets, typeName: typeName)
        let perRowValues = try groupByOffsets(perEntryValues, offsets: offsets, stage: "decoder.map", typeName: typeName)
        return .init(column: .mapWithArrayValues(keys: perRowKeys, values: perRowValues, keyElement: keyElement, valueElement: valueElement), nextOffset: cursor)
    }

    // Map(K, V) where K and/or V is LowCardinality. Each LowCardinality side
    // hoists its KeysSerializationVersion (8 bytes) ahead of the map offsets, in
    // key-then-value order, the same as Array(LowCardinality); reading it inline
    // with the dictionary would mis-frame the block and desync the connection.
    // After the offsets, each side's body follows: a LowCardinality side carries
    // its dictionary bulk (omitted when the map has no entries), a plain side its
    // flattened elements. Resolving each LowCardinality key through its dictionary
    // yields a plain Map column whose element type mirrors the dictionary, so the
    // existing [String: V] decode handles it unchanged.
    private static func parseMapWithLowCardinalitySidesColumn(
        typeName: String,
        keyTypeName: String,
        valueTypeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let keyElement = try mapSideElementType(typeName: keyTypeName, mapTypeName: typeName)
        let valueElement = try mapSideElementType(typeName: valueTypeName, mapTypeName: typeName)
        if rowCount == 0 {
            return .init(column: .map(keys: [], values: [], keyElement: keyElement, valueElement: valueElement), nextOffset: offset)
        }
        var cursor = offset
        if keyTypeName.hasPrefix("LowCardinality(") {
            _ = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
            cursor += 8
        }
        if valueTypeName.hasPrefix("LowCardinality(") {
            _ = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
            cursor += 8
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor += rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: typeName, stage: "decoder.map")
        let keySide = try readMapSideElements(typeName: keyTypeName, totalElements: totalElements, base: base, offset: cursor, limit: limit, mapTypeName: typeName)
        cursor = keySide.nextOffset
        let valueSide = try readMapSideElements(typeName: valueTypeName, totalElements: totalElements, base: base, offset: cursor, limit: limit, mapTypeName: typeName)
        cursor = valueSide.nextOffset
        let perRowKeys = try groupArrayElements(keySide.elements, offsets: offsets, typeName: typeName)
        let perRowValues = try groupArrayElements(valueSide.elements, offsets: offsets, typeName: typeName)
        return .init(column: .map(keys: perRowKeys, values: perRowValues, keyElement: keyElement, valueElement: valueElement), nextOffset: cursor)
    }

    private static func mapSideElementType(typeName: String, mapTypeName: String) throws(ClickHouseError) -> ClickHouseArrayElementType {
        if typeName.hasPrefix("LowCardinality(") {
            return arrayElementType(forLowCardinalityInner: try parseLowCardinalityInner(typeName: typeName))
        }
        return try parseMapElementType(typeName: typeName, mapTypeName: mapTypeName)
    }

    private struct MapSideElements {
        let elements: [[UInt8]]
        let nextOffset: Int
    }

    private static func readMapSideElements(typeName: String, totalElements: Int, base: UnsafePointer<UInt8>, offset: Int, limit: Int, mapTypeName: String) throws(ClickHouseError) -> MapSideElements {
        guard typeName.hasPrefix("LowCardinality(") else {
            let element = try parseMapElementType(typeName: typeName, mapTypeName: mapTypeName)
            let flat = try readArrayElements(element: element, count: totalElements, base: base, offset: offset, limit: limit, typeName: mapTypeName)
            return MapSideElements(elements: flat.elements, nextOffset: flat.nextOffset)
        }
        if totalElements == 0 {
            return MapSideElements(elements: [], nextOffset: offset)
        }
        let inner = try parseLowCardinalityInner(typeName: typeName)
        let structure = try readLowCardinalityBulk(inner: inner, typeName: mapTypeName, base: base, offset: offset, limit: limit)
        guard structure.indices.count == totalElements else {
            throw .protocolError(stage: "decoder.map", message: "low-cardinality index count \(structure.indices.count) does not match map element count \(totalElements) in \(mapTypeName)")
        }
        let elements = structure.indices.map { structure.dictionary[$0] }
        return MapSideElements(elements: elements, nextOffset: structure.nextOffset)
    }

    private static func parseVariantColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let members = try parseVariantMemberTypes(typeName: typeName)
        if members.count > 255 {
            throw ClickHouseError.protocolError(stage: "decoder.variant", message: "Variant declares \(members.count) members; the wire discriminator is one byte and supports at most 255")
        }
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
        if members.count > 255 {
            throw ClickHouseError.protocolError(stage: "decoder.dynamic", message: "Dynamic declares \(members.count) members; the wire discriminator is one byte and supports at most 255")
        }
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
            let memberCountInt = try boundedElementCount(memberCount.0, available: limit - cursor, typeName: "Dynamic", stage: "decoder.parseDynamic")
            var members: [ClickHouseArrayElementType] = []
            members.reserveCapacity(memberCountInt)
            for _ in 0..<memberCountInt {
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
        let parsed = try parseArrayOfTupleElementTypes(innerTupleTypeName: innerTupleTypeName)
        if rowCount == 0 {
            let empty = Array(repeating: [[[UInt8]]](), count: parsed.elements.count)
            return .init(
                column: .arrayOfTuple(elementValues: empty, elements: parsed.elements, names: parsed.names),
                nextOffset: offset
            )
        }
        let offsets: [UInt64] = try parseFixedWidth(rowCount: rowCount, base: base, offset: offset, limit: limit, typeName: innerTupleTypeName)
        var cursor = offset + rowCount * 8
        let totalElements = try boundedElementCount(offsets[rowCount - 1], available: limit - cursor, typeName: innerTupleTypeName, stage: "decoder.arrayOfTuple")
        var elementValues: [[[[UInt8]]]] = []
        elementValues.reserveCapacity(parsed.elements.count)
        for element in parsed.elements {
            let flat = try readArrayElements(element: element, count: totalElements, base: base, offset: cursor, limit: limit, typeName: innerTupleTypeName)
            cursor = flat.nextOffset
            elementValues.append(try groupArrayElements(flat.elements, offsets: offsets, typeName: innerTupleTypeName))
        }
        return .init(
            column: .arrayOfTuple(elementValues: elementValues, elements: parsed.elements, names: parsed.names),
            nextOffset: cursor
        )
    }

    private static func parseArrayOfTupleElementTypes(innerTupleTypeName: String) throws(ClickHouseError) -> (elements: [ClickHouseArrayElementType], names: [String]) {
        let splitElements = try ClickHouseTupleTypeSplitter.split(typeName: innerTupleTypeName)
        if splitElements.count < 2 {
            throw .protocolError(stage: "decoder.arrayOfTuple", message: "Array(Tuple) needs at least 2 inner types, got \(splitElements.count) in \(innerTupleTypeName)")
        }
        var types: [ClickHouseArrayElementType] = []
        types.reserveCapacity(splitElements.count)
        var names: [String] = []
        names.reserveCapacity(splitElements.count)
        for element in splitElements {
            types.append(try parseMapElementType(typeName: element.type, mapTypeName: innerTupleTypeName))
            names.append(element.name)
        }
        return (types, names)
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
        case "Bool": return .bool
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
        case "DateTime": return .dateTime
        case "Date": return .date
        case "Date32": return .date32
        case "UUID": return .uuid
        case "IPv4": return .ipv4
        case "IPv6": return .ipv6
        case "Int128": return .int128
        case "UInt128": return .uint128
        case "Int256": return .int256
        case "UInt256": return .uint256
        default:
            if typeName.hasPrefix("DateTime64(") {
                return .dateTime64(precision: try parseDateTime64Precision(typeName: typeName))
            }
            if typeName.hasPrefix("DateTime(") {
                return .dateTime
            }
            if typeName.hasPrefix("Decimal") {
                let parameters = try parseDecimalParameters(typeName: typeName)
                return .decimal(precision: parameters.precision, scale: parameters.scale)
            }
            if typeName.hasPrefix("Enum8(") {
                return .enum8(mapping: try parseEnumMapping(typeName: typeName, prefixCount: "Enum8(".utf8.count))
            }
            if typeName.hasPrefix("Enum16(") {
                return .enum16(mapping: try parseEnumMapping(typeName: typeName, prefixCount: "Enum16(".utf8.count))
            }
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
            guard let end = Int(exactly: offset) else {
                throw .protocolError(stage: "decoder.array", message: "offset \(offset) exceeds Int range in \(typeName)")
            }
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
            let (byteStrings, consumed) = try parseStringColumn(rowCount: count, base: base, offset: offset, limit: limit)
            return ArrayElementsResult(elements: byteStrings, nextOffset: offset + consumed)
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
        case "Bool": return .bool
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
        case "UUID":
            return .uuid
        case "IPv4":
            return .ipv4
        case "IPv6":
            return .ipv6
        case "Int128":
            return .int128
        case "UInt128":
            return .uint128
        case "Int256":
            return .int256
        case "UInt256":
            return .uint256
        case "DateTime":
            return .dateTime
        case "Date":
            return .date
        case "Date32":
            return .date32
        default:
            if inner.hasPrefix("DateTime64(") {
                return .dateTime64(precision: try parseDateTime64Precision(typeName: inner))
            }
            if inner.hasPrefix("DateTime(") {
                return .dateTime
            }
            if inner.hasPrefix("Decimal") {
                let parameters = try parseDecimalParameters(typeName: inner)
                return .decimal(precision: parameters.precision, scale: parameters.scale)
            }
            if inner.hasPrefix("Enum8(") {
                return .enum8(mapping: try parseEnumMapping(typeName: inner, prefixCount: "Enum8(".utf8.count))
            }
            if inner.hasPrefix("Enum16(") {
                return .enum16(mapping: try parseEnumMapping(typeName: inner, prefixCount: "Enum16(".utf8.count))
            }
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
        if lowCardinalityInnerTypeName(typeName).hasPrefix("Nullable(") {
            return try parseNullableLowCardinalityColumn(typeName: typeName, rowCount: rowCount, base: base, offset: offset, limit: limit)
        }
        let inner = try parseLowCardinalityInner(typeName: typeName)
        if rowCount == 0 {
            return .init(column: .lowCardinality([], inner: inner), nextOffset: offset)
        }
        let structure = try readLowCardinalityStructure(inner: inner, typeName: typeName, base: base, offset: offset, limit: limit)
        // A valid LowCardinality column carries exactly one index per row. A
        // malformed or hostile server can declare an index count below the
        // block's row count; the resulting short column would then be indexed
        // out of bounds (a trap) while decoding later rows. Reject the
        // mismatch here so it surfaces as a typed error, not a crash.
        guard structure.indices.count == rowCount else {
            throw .protocolError(stage: "decoder.lowCardinality", message: "index count \(structure.indices.count) does not match block row count \(rowCount) in \(typeName)")
        }
        let perRow = structure.indices.map { structure.dictionary[$0] }
        return .init(column: .lowCardinality(perRow, inner: inner), nextOffset: structure.nextOffset)
    }

    // LowCardinality(Nullable(String)) reserves dictionary index 0 as the NULL
    // placeholder, so a key of 0 is a NULL row and every other key resolves to
    // its dictionary entry. Reading it into a .nullableString column lets the
    // existing String and String? decode paths handle it like any other nullable
    // string, without a dedicated LowCardinality-nullable representation.
    private static func parseNullableLowCardinalityColumn(
        typeName: String,
        rowCount: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> ColumnParseResult {
        let innerName = lowCardinalityInnerTypeName(typeName)
        let valueTypeName = String(innerName.dropFirst("Nullable(".count).dropLast())
        guard valueTypeName == "String" else {
            throw .protocolError(stage: "decoder.lowCardinality", message: "unsupported LowCardinality inner type \(innerName)")
        }
        if rowCount == 0 {
            return .init(column: .nullableString([]), nextOffset: offset)
        }
        let structure = try readLowCardinalityStructure(inner: .string, typeName: typeName, base: base, offset: offset, limit: limit)
        guard structure.indices.count == rowCount else {
            throw .protocolError(stage: "decoder.lowCardinality", message: "index count \(structure.indices.count) does not match block row count \(rowCount) in \(typeName)")
        }
        let rows = nullableLowCardinalityRows(indices: structure.indices, dictionary: structure.dictionary)
        return .init(column: .nullableString(rows), nextOffset: structure.nextOffset)
    }

    private static func nullableLowCardinalityRows(indices: [Int], dictionary: [[UInt8]]) -> [ClickHouseNullable<[UInt8]>] {
        indices.map { $0 == 0 ? .absent : .present(dictionary[$0]) }
    }

    private struct LowCardinalityStructure {
        let dictionary: [[UInt8]]
        let indices: [Int]
        let nextOffset: Int
    }

    // The state prefix (an 8-byte key-version scalar) precedes the dictionary
    // bulk for a top-level LowCardinality column. Inside Array(LowCardinality),
    // the prefix is emitted once before the array offsets, so that caller reads
    // the prefix itself and invokes readLowCardinalityBulk directly.
    private static func readLowCardinalityStructure(
        inner: ClickHouseLowCardinalityInner,
        typeName: String,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> LowCardinalityStructure {
        _ = try readUInt64Scalar(base: base, offset: offset, limit: limit)
        return try readLowCardinalityBulk(inner: inner, typeName: typeName, base: base, offset: offset + 8, limit: limit)
    }

    private static func readLowCardinalityBulk(
        inner: ClickHouseLowCardinalityInner,
        typeName: String,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int
    ) throws(ClickHouseError) -> LowCardinalityStructure {
        var cursor = offset
        let serializationType = try readUInt64Scalar(base: base, offset: cursor, limit: limit)
        cursor += 8
        let width = ClickHouseLowCardinalityWire.keyWidth(serializationType: serializationType)
        let dictionarySize = try boundedElementCount(readUInt64Scalar(base: base, offset: cursor, limit: limit), available: limit - cursor - 8, typeName: typeName, stage: "decoder.lowCardinality")
        cursor += 8
        let dictionaryResult = try readLowCardinalityDictionary(inner: inner, dictionarySize: dictionarySize, base: base, offset: cursor, limit: limit)
        cursor = dictionaryResult.nextOffset
        let indicesCount = try boundedElementCount(readUInt64Scalar(base: base, offset: cursor, limit: limit), available: limit - cursor - 8, typeName: typeName, stage: "decoder.lowCardinality")
        cursor += 8
        let indices = try readLowCardinalityRawIndices(count: indicesCount, width: width, dictionarySize: dictionaryResult.dictionary.count, base: base, offset: cursor, limit: limit, typeName: typeName)
        cursor += indicesCount * width
        return LowCardinalityStructure(dictionary: dictionaryResult.dictionary, indices: indices, nextOffset: cursor)
    }

    // Converts a server-supplied element/offset count to an Int, rejecting a
    // value above Int (an unchecked Int(UInt64) conversion would trap) or one
    // larger than the bytes remaining (each element occupies at least one
    // byte, so a count exceeding the available bytes is malformed and would
    // otherwise drive an absurd allocation).
    private static func boundedElementCount(_ raw: UInt64, available: Int, typeName: String, stage: String) throws(ClickHouseError) -> Int {
        guard let count = Int(exactly: raw), count <= Swift.max(0, available) else {
            throw .protocolError(stage: stage, message: "element count \(raw) exceeds the \(Swift.max(0, available)) bytes available in \(typeName)")
        }
        return count
    }

    private static func readUInt64Scalar(base: UnsafePointer<UInt8>, offset: Int, limit: Int) throws(ClickHouseError) -> UInt64 {
        let values: [UInt64] = try parseFixedWidth(rowCount: 1, base: base, offset: offset, limit: limit, typeName: "LowCardinality")
        return values[0]
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
            let (byteStrings, consumed) = try parseStringColumn(rowCount: dictionarySize, base: base, offset: offset, limit: limit)
            return LowCardinalityDictionaryResult(dictionary: byteStrings, nextOffset: offset + consumed)
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

    private static func readLowCardinalityRawIndices(
        count: Int,
        width: Int,
        dictionarySize: Int,
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        typeName: String
    ) throws(ClickHouseError) -> [Int] {
        try requireBytes(count * width, available: limit - offset, typeName: typeName)
        var indices: [Int] = []
        indices.reserveCapacity(count)
        for index in 0..<count {
            let dictionaryIndex = readLittleEndianIndex(base: base, offset: offset + index * width, width: width)
            if dictionaryIndex < 0 || dictionaryIndex >= dictionarySize {
                throw .protocolError(stage: "decoder.lowCardinality", message: "index \(dictionaryIndex) out of dictionary range \(dictionarySize) in \(typeName)")
            }
            indices.append(dictionaryIndex)
        }
        return indices
    }

    private static func readLittleEndianIndex(base: UnsafePointer<UInt8>, offset: Int, width: Int) -> Int {
        var value: UInt64 = 0
        for byteIndex in 0..<width {
            value |= UInt64(base[offset + byteIndex]) << (8 * byteIndex)
        }
        return Int(truncatingIfNeeded: value)
    }

    private static func lowCardinalityInnerTypeName(_ typeName: String) -> String {
        String(typeName.dropFirst("LowCardinality(".count).dropLast())
    }

    private static func parseLowCardinalityInner(typeName: String) throws(ClickHouseError) -> ClickHouseLowCardinalityInner {
        let inner = lowCardinalityInnerTypeName(typeName)
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
        while cursor < bytes.count {
            if bytes[cursor] == 0x5c, cursor + 1 < bytes.count {
                nameBytes.append(bytes[cursor + 1])
                cursor += 2
                continue
            }
            if bytes[cursor] == 0x27 { break }
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

    package static func parseFixedStringLength(typeName: String) throws(ClickHouseError) -> Int {
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

    package static func parseDecimalParameters(typeName: String) throws(ClickHouseError) -> (precision: UInt8, scale: UInt8) {
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
        if scaleScan.value > 76 {
            throw .protocolError(stage: "decoder.decimal", message: "scale out of range in \(typeName)")
        }
        return (UInt8(precisionScan.value), UInt8(scaleScan.value))
    }

    private static func parseSingleDecimalScale(typeName: String, prefix: String) throws(ClickHouseError) -> UInt8 {
        let inner = Substring(typeName.dropFirst(prefix.count))
        let scan = scanDecimalInteger(inner)
        if scan.digitCount == 0 {
            throw .protocolError(stage: "decoder.decimal", message: "missing scale in \(typeName)")
        }
        if scan.value > 76 {
            throw .protocolError(stage: "decoder.decimal", message: "scale out of range in \(typeName)")
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
    ) throws(ClickHouseError) -> ([[UInt8]], Int) {
        var values: [[UInt8]] = []
        values.reserveCapacity(rowCount)
        var cursor = offset
        for _ in 0..<rowCount {
            do {
                let (slice, consumed) = try ClickHouseWire.readStringSlice(base: base, offset: cursor, limit: limit)
                values.append(Array(slice))
                cursor += consumed
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
