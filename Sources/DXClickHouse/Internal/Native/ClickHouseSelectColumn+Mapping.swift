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

extension ClickHouseSelectColumn {

    static func from(name: String, internalColumn column: any ClickHouseColumn) throws -> ClickHouseSelectColumn {
        let values = try mapToValues(column: column)
        return ClickHouseSelectColumn(name: name, typeName: column.spec.typeName, values: values)
    }

}

private func mapToValues(column: any ClickHouseColumn) throws -> ClickHouseColumnEntry.Values {
    switch column.spec {
    case .int8: return .int8(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int8>.self).values)
    case .int16: return .int16(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int16>.self).values)
    case .int32: return .int32(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int32>.self).values)
    case .int64: return .int64(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int64>.self).values)
    case .int128: return .int128(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int128>.self).values)
    case .uint8: return .uint8(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt8>.self).values)
    case .uint16: return .uint16(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values)
    case .uint32: return .uint32(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values)
    case .uint64: return .uint64(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt64>.self).values)
    case .uint128: return .uint128(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt128>.self).values)
    case .float32: return .float32(try requireColumn(column, ClickHouseFloat32Column.self).values)
    case .float64: return .float64(try requireColumn(column, ClickHouseFloat64Column.self).values)
    case .string: return .string(try requireColumn(column, ClickHouseStringColumn.self).values)
    case .bool: return .bool(try requireColumn(column, ClickHouseBoolColumn.self).values)
    case .uuid: return .uuid(try requireColumn(column, ClickHouseUUIDColumn.self).values)
    case .ipv4: return .ipv4(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values)
    case .ipv6: return .ipv6(try requireColumn(column, ClickHouseFixedStringColumn.self).values)
    case .json: return .json(try requireColumn(column, ClickHouseStringColumn.self).values)
    case .fixedString(let length):
        return .fixedString(length: length, try requireColumn(column, ClickHouseFixedStringColumn.self).values)
    case .date: return try mapDate(column: column)
    case .date32: return try mapDate32(column: column)
    case .dateTime: return try mapDateTime(column: column)
    case .dateTime64(let precision, _): return try mapDateTime64(column: column, precision: precision)
    case .decimal32(let scale):
        return .decimal32(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, scale: scale)
    case .decimal64(let scale):
        return .decimal64(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, scale: scale)
    case .decimal128(let scale):
        return .decimal128(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int128>.self).values, scale: scale)
    case .decimal256(let scale):
        return .decimal256(try requireColumn(column, ClickHouseInt256Column.self).values, scale: scale)
    case .time:
        return .time(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int32>.self).values)
    case .time64(let precision):
        return .time64(try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, precision: precision)
    case .interval(let kind):
        return .interval(kind: kind, values: try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int64>.self).values)
    case .int256:
        return .int256(try requireColumn(column, ClickHouseInt256Column.self).values)
    case .uint256:
        return .uint256(try requireColumn(column, ClickHouseUInt256Column.self).values)
    case .bfloat16:
        return .bfloat16(try requireColumn(column, ClickHouseBFloat16Column.self).values)
    case .enum8(let entries): return try mapEnum8(column: column, entries: entries)
    case .enum16(let entries): return try mapEnum16(column: column, entries: entries)
    case .nullable: return try mapNullable(try requireColumn(column, ClickHouseNullableColumn.self))
    case .array: return try mapArray(try requireColumn(column, ClickHouseArrayColumn.self))
    case .tuple: return try mapTuple(try requireColumn(column, ClickHouseTupleColumn.self))
    case .map: return try mapMap(try requireColumn(column, ClickHouseMapColumn.self))
    case .lowCardinality: return try mapLowCardinality(try requireColumn(column, ClickHouseLowCardinalityColumn.self))
    case .nothing: throw ClickHouseError.unsupportedSelectColumnType(typeName: column.spec.typeName)
    }
}

private func mapDate(column: any ClickHouseColumn) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values
    return .date(raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0)) * 86_400) })
}

private func mapDate32(column: any ClickHouseColumn) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int32>.self).values
    return .date32(raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0)) * 86_400) })
}

private func mapDateTime(column: any ClickHouseColumn) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values
    return .dateTime(raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0))) })
}

private func mapDateTime64(column: any ClickHouseColumn, precision: Int) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    let multiplier = ClickHouseClient.nanosecondsToColumnDivisor(precision: precision)
    let nanos = try raw.map { tick -> ClickHouseNanoseconds in
        try multiplyTickToNanoseconds(tick: tick, multiplier: multiplier, precision: precision)
    }
    return .dateTime64Nanoseconds(nanos, precision: precision)
}

private func multiplyTickToNanoseconds(tick: Int64, multiplier: Int64, precision: Int) throws -> ClickHouseNanoseconds {
    let (product, overflow) = tick.multipliedReportingOverflow(by: multiplier)
    guard !overflow else {
        throw ClickHouseError.dateTime64TickToNanosecondsOverflow(
            ticks: tick,
            precision: precision
        )
    }
    return ClickHouseNanoseconds(product)
}

private func mapEnum8(column: any ClickHouseColumn, entries: [ClickHouseEnumValue<Int8>]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int8>.self).values
    let labelByValue = makeEnum8LookupTable(entries: entries)
    return .string(raw.map { labelByValue[$0] ?? String($0) })
}

private func mapEnum16(column: any ClickHouseColumn, entries: [ClickHouseEnumValue<Int16>]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(column, ClickHouseFixedWidthIntegerColumn<Int16>.self).values
    let labelByValue = makeEnum16LookupTable(entries: entries)
    return .string(raw.map { labelByValue[$0] ?? String($0) })
}

private func makeEnum8LookupTable(entries: [ClickHouseEnumValue<Int8>]) -> [Int8: String] {
    var labelByValue: [Int8: String] = [:]
    labelByValue.reserveCapacity(entries.count)
    for entry in entries { labelByValue[entry.value] = entry.name }
    return labelByValue
}

private func makeEnum16LookupTable(entries: [ClickHouseEnumValue<Int16>]) -> [Int16: String] {
    var labelByValue: [Int16: String] = [:]
    labelByValue.reserveCapacity(entries.count)
    for entry in entries { labelByValue[entry.value] = entry.name }
    return labelByValue
}

private func mapLowCardinality(_ lc: ClickHouseLowCardinalityColumn) throws -> ClickHouseColumnEntry.Values {
    switch lc.innerSpec {
    case .string:
        let view = try resolveLowCardinalityStringView(keyColumn: lc)
        return .lowCardinalityStringIndexed(view)
    default: throw ClickHouseError.unsupportedSelectColumnType(typeName: lc.spec.typeName)
    }
}

private func mapMap(_ map: ClickHouseMapColumn) throws -> ClickHouseColumnEntry.Values {
    let offsets = map.offsets
    switch (map.keySpec, map.valueSpec) {
    case (.string, .string): return try mapMapStringString(map: map, offsets: offsets)
    case (.lowCardinality(.string), .string): return try mapMapLCStringString(map: map, offsets: offsets)
    case (.string, .int32): return try mapMapStringInt32(map: map, offsets: offsets)
    case (.string, .int64): return try mapMapStringInt64(map: map, offsets: offsets)
    case (.string, .float64): return try mapMapStringFloat64(map: map, offsets: offsets)
    case (.string, .bool): return try mapMapStringBool(map: map, offsets: offsets)
    case (.int32, .string): return try mapMapInt32String(map: map, offsets: offsets)
    case (.int64, .string): return try mapMapInt64String(map: map, offsets: offsets)
    case (.string, .float32): return try mapMapStringFloat32(map: map, offsets: offsets)
    case (.string, .uuid): return try mapMapStringUUID(map: map, offsets: offsets)
    case (.string, .dateTime): return try mapMapStringDateTime(map: map, offsets: offsets)
    case (.uint64, .int64): return try mapMapUInt64Int64(map: map, offsets: offsets)
    default: throw ClickHouseError.unsupportedSelectColumnType(typeName: map.spec.typeName)
    }
}

private func mapMapStringString(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseStringColumn.self).values
    let storage = ClickHouseMapStringStringStorage(keys: .direct(k), values: v, offsets: offsets)
    return .mapStringStringIndexed(storage)
}

private func mapMapLCStringString(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let keyColumn = try requireColumn(map.keys, ClickHouseLowCardinalityColumn.self)
    let view = try resolveLowCardinalityStringView(keyColumn: keyColumn)
    let v = try requireColumn(map.values, ClickHouseStringColumn.self).values
    let storage = ClickHouseMapStringStringStorage(
        keys: .lowCardinality(dictionary: view.dictionary, indices: view.indices),
        values: v,
        offsets: offsets
    )
    return .mapStringStringIndexed(storage)
}

private func resolveLowCardinalityStringView(keyColumn: ClickHouseLowCardinalityColumn) throws -> ClickHouseLowCardinalityStringView {
    let dictionary = try requireColumn(keyColumn.dictionary, ClickHouseStringColumn.self).values
    let indices = keyColumn.indices
    try validateLowCardinalityIndices(indices: indices, dictionarySize: dictionary.count)
    return ClickHouseLowCardinalityStringView(dictionary: dictionary, indices: indices)
}

private func validateLowCardinalityIndices(indices: [UInt64], dictionarySize: Int) throws {
    let dictionaryBound = UInt64(dictionarySize)
    for rawIndex in indices {
        if rawIndex >= dictionaryBound {
            throw ClickHouseError.lowCardinalityDictionaryIndexOutOfRange(
                index: Int(clamping: rawIndex),
                dictionarySize: dictionarySize
            )
        }
    }
}

private func mapMapStringInt32(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseFixedWidthIntegerColumn<Int32>.self).values
    return .mapStringInt32(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringInt64(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    return .mapStringInt64(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringFloat64(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseFloat64Column.self).values
    return .mapStringFloat64(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringBool(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseBoolColumn.self).values
    return .mapStringBool(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapInt32String(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseFixedWidthIntegerColumn<Int32>.self).values
    let v = try requireColumn(map.values, ClickHouseStringColumn.self).values
    return .mapInt32String(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapInt64String(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    let v = try requireColumn(map.values, ClickHouseStringColumn.self).values
    return .mapInt64String(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringFloat32(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseFloat32Column.self).values
    return .mapStringFloat32(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringUUID(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let v = try requireColumn(map.values, ClickHouseUUIDColumn.self).values
    return .mapStringUUID(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func mapMapStringDateTime(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseStringColumn.self).values
    let raw = try requireColumn(map.values, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values
    let dates = raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0))) }
    return .mapStringDateTime(sliceMapByOffsets(keys: k, values: dates, offsets: offsets))
}

private func mapMapUInt64Int64(map: ClickHouseMapColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let k = try requireColumn(map.keys, ClickHouseFixedWidthIntegerColumn<UInt64>.self).values
    let v = try requireColumn(map.values, ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    return .mapUInt64Int64(sliceMapByOffsets(keys: k, values: v, offsets: offsets))
}

private func sliceMapByOffsets<K: Hashable, V>(
    keys: [K], values: [V], offsets: [UInt64]
) -> [[K: V]] {
    var result: [[K: V]] = []
    result.reserveCapacity(offsets.count)
    var previous: UInt64 = 0
    for offset in offsets {
        let start = Int(previous)
        let end = Int(offset)
        var row: [K: V] = [:]
        row.reserveCapacity(end - start)
        for index in start..<end {
            row[keys[index]] = values[index]
        }
        result.append(row)
        previous = offset
    }
    return result
}

private func mapTuple(_ tuple: ClickHouseTupleColumn) throws -> ClickHouseColumnEntry.Values {
    switch tuple.elementSpecs {
    case [.float64, .float64]: return .tupleFloat64Float64(try extractFloat64Pairs(tuple))
    case [.string, .string]: return try mapTupleStringString(tuple: tuple)
    case [.string, .int32]: return try mapTupleStringInt32(tuple: tuple)
    case [.string, .int64]: return try mapTupleStringInt64(tuple: tuple)
    default: throw ClickHouseError.unsupportedSelectColumnType(typeName: tuple.spec.typeName)
    }
}

private func mapTupleStringString(tuple: ClickHouseTupleColumn) throws -> ClickHouseColumnEntry.Values {
    let first = try requireColumn(tuple.elements[0], ClickHouseStringColumn.self).values
    let second = try requireColumn(tuple.elements[1], ClickHouseStringColumn.self).values
    return .tupleStringString(zip(first, second).map { ($0, $1) })
}

private func mapTupleStringInt32(tuple: ClickHouseTupleColumn) throws -> ClickHouseColumnEntry.Values {
    let first = try requireColumn(tuple.elements[0], ClickHouseStringColumn.self).values
    let second = try requireColumn(tuple.elements[1], ClickHouseFixedWidthIntegerColumn<Int32>.self).values
    return .tupleStringInt32(zip(first, second).map { ($0, $1) })
}

private func mapTupleStringInt64(tuple: ClickHouseTupleColumn) throws -> ClickHouseColumnEntry.Values {
    let first = try requireColumn(tuple.elements[0], ClickHouseStringColumn.self).values
    let second = try requireColumn(tuple.elements[1], ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    return .tupleStringInt64(zip(first, second).map { ($0, $1) })
}

private func extractFloat64Pairs(_ tuple: ClickHouseTupleColumn) throws -> [(Double, Double)] {
    guard tuple.elementSpecs == [.float64, .float64] else {
        throw ClickHouseError.unsupportedSelectColumnType(typeName: tuple.spec.typeName)
    }
    let first = try requireColumn(tuple.elements[0], ClickHouseFloat64Column.self).values
    let second = try requireColumn(tuple.elements[1], ClickHouseFloat64Column.self).values
    return zip(first, second).map { ($0, $1) }
}

private func mapArray(_ array: ClickHouseArrayColumn) throws -> ClickHouseColumnEntry.Values {
    let offsets = array.offsets
    switch array.elementSpec {
    case .int8: return .arrayOfInt8(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<Int8>.self).values, offsets: offsets))
    case .int16: return .arrayOfInt16(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<Int16>.self).values, offsets: offsets))
    case .int32: return .arrayOfInt32(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, offsets: offsets))
    case .int64: return .arrayOfInt64(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, offsets: offsets))
    case .uint8: return .arrayOfUInt8(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt8>.self).values, offsets: offsets))
    case .uint16: return .arrayOfUInt16(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values, offsets: offsets))
    case .uint32: return .arrayOfUInt32(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values, offsets: offsets))
    case .uint64: return .arrayOfUInt64(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt64>.self).values, offsets: offsets))
    case .float32: return .arrayOfFloat32(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFloat32Column.self).values, offsets: offsets))
    case .float64: return .arrayOfFloat64(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseFloat64Column.self).values, offsets: offsets))
    case .string: return .arrayOfString(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseStringColumn.self).values, offsets: offsets))
    case .bool: return .arrayOfBool(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseBoolColumn.self).values, offsets: offsets))
    case .uuid: return .arrayOfUUID(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseUUIDColumn.self).values, offsets: offsets))
    case .date: return try mapArrayDate(array: array, offsets: offsets)
    case .dateTime: return try mapArrayDateTime(array: array, offsets: offsets)
    case .bfloat16: return .arrayOfBFloat16(sliceByOffsets(values: try requireColumn(array.inner, ClickHouseBFloat16Column.self).values, offsets: offsets))
    case .tuple(let elementSpecs) where elementSpecs == [.float64, .float64]:
        return try mapArrayOfRing(array: array, offsets: offsets)
    case .array(let nested) where nested == .tuple(elements: [.float64, .float64]):
        return try mapArrayOfPolygon(array: array, offsets: offsets)
    case .array(let nested) where nested == .array(of: .tuple(elements: [.float64, .float64])):
        return try mapArrayOfMultiPolygon(array: array, offsets: offsets)
    case .int128, .uint128, .int256, .uint256, .date32, .dateTime64, .time, .time64,
         .decimal32, .decimal64, .decimal128, .decimal256, .fixedString, .ipv4, .ipv6,
         .json, .enum8, .enum16, .interval, .nothing,
         .array, .nullable, .tuple, .map, .lowCardinality:
        throw ClickHouseError.unsupportedSelectColumnType(typeName: array.spec.typeName)
    }
}

private func mapArrayDate(array: ClickHouseArrayColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values
    let dates = raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0)) * 86_400) }
    return .arrayOfDate(sliceByOffsets(values: dates, offsets: offsets))
}

private func mapArrayDateTime(array: ClickHouseArrayColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(array.inner, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values
    let dates = raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0))) }
    return .arrayOfDateTime(sliceByOffsets(values: dates, offsets: offsets))
}

// Ring = Array(Tuple(Float64, Float64))
private func mapArrayOfRing(array: ClickHouseArrayColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let tupleColumn = try requireColumn(array.inner, ClickHouseTupleColumn.self)
    let pairs = try extractFloat64Pairs(tupleColumn)
    return .arrayOfTupleFloat64Float64(sliceByOffsets(values: pairs, offsets: offsets))
}

// Polygon = Array(Array(Tuple(Float64, Float64)))
private func mapArrayOfPolygon(array: ClickHouseArrayColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let ringArrayColumn = try requireColumn(array.inner, ClickHouseArrayColumn.self)
    let tupleColumn = try requireColumn(ringArrayColumn.inner, ClickHouseTupleColumn.self)
    let pairs = try extractFloat64Pairs(tupleColumn)
    let rings = sliceByOffsets(values: pairs, offsets: ringArrayColumn.offsets)
    let polygons = sliceByOffsets(values: rings, offsets: offsets)
    return .arrayOfArrayOfTupleFloat64Float64(polygons)
}

// MultiPolygon = Array(Array(Array(Tuple(Float64, Float64))))
private func mapArrayOfMultiPolygon(array: ClickHouseArrayColumn, offsets: [UInt64]) throws -> ClickHouseColumnEntry.Values {
    let polygonArrayColumn = try requireColumn(array.inner, ClickHouseArrayColumn.self)
    let ringArrayColumn = try requireColumn(polygonArrayColumn.inner, ClickHouseArrayColumn.self)
    let tupleColumn = try requireColumn(ringArrayColumn.inner, ClickHouseTupleColumn.self)
    let pairs = try extractFloat64Pairs(tupleColumn)
    let rings = sliceByOffsets(values: pairs, offsets: ringArrayColumn.offsets)
    let polygons = sliceByOffsets(values: rings, offsets: polygonArrayColumn.offsets)
    let multiPolygons = sliceByOffsets(values: polygons, offsets: offsets)
    return .arrayOfArrayOfArrayOfTupleFloat64Float64(multiPolygons)
}

private func sliceByOffsets<T>(values: [T], offsets: [UInt64]) -> [[T]] {
    var result: [[T]] = []
    result.reserveCapacity(offsets.count)
    var previous: UInt64 = 0
    for offset in offsets {
        let start = Int(previous)
        let end = Int(offset)
        result.append(Array(values[start..<end]))
        previous = offset
    }
    return result
}

private func mapNullable(_ nullable: ClickHouseNullableColumn) throws -> ClickHouseColumnEntry.Values {
    let mask = nullable.nullMask
    switch nullable.innerSpec {
    case .int8: return .nullableInt8(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int8>.self).values, mask: mask))
    case .int16: return .nullableInt16(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int16>.self).values, mask: mask))
    case .int32: return .nullableInt32(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, mask: mask))
    case .int64: return .nullableInt64(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, mask: mask))
    case .int128: return .nullableInt128(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int128>.self).values, mask: mask))
    case .uint8: return .nullableUInt8(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt8>.self).values, mask: mask))
    case .uint16: return .nullableUInt16(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values, mask: mask))
    case .uint32: return .nullableUInt32(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values, mask: mask))
    case .uint64: return .nullableUInt64(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt64>.self).values, mask: mask))
    case .uint128: return .nullableUInt128(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt128>.self).values, mask: mask))
    case .float32: return .nullableFloat32(applyMask(values: try requireColumn(nullable.inner, ClickHouseFloat32Column.self).values, mask: mask))
    case .float64: return .nullableFloat64(applyMask(values: try requireColumn(nullable.inner, ClickHouseFloat64Column.self).values, mask: mask))
    case .string: return .nullableString(applyMask(values: try requireColumn(nullable.inner, ClickHouseStringColumn.self).values, mask: mask))
    case .bool: return .nullableBool(applyMask(values: try requireColumn(nullable.inner, ClickHouseBoolColumn.self).values, mask: mask))
    case .uuid: return .nullableUUID(applyMask(values: try requireColumn(nullable.inner, ClickHouseUUIDColumn.self).values, mask: mask))
    case .date: return try mapNullableDate(nullable: nullable, mask: mask)
    case .date32: return .nullableDate32(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, mask: mask))
    case .dateTime: return try mapNullableDateTime(nullable: nullable, mask: mask)
    case .dateTime64(let precision, _): return try mapNullableDateTime64(nullable: nullable, mask: mask, precision: precision)
    case .decimal32(let scale): return .nullableDecimal32(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, mask: mask), scale: scale)
    case .decimal64(let scale): return .nullableDecimal64(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, mask: mask), scale: scale)
    case .decimal128(let scale): return .nullableDecimal128(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int128>.self).values, mask: mask), scale: scale)
    case .decimal256(let scale): return .nullableDecimal256(applyMask(values: try requireColumn(nullable.inner, ClickHouseInt256Column.self).values, mask: mask), scale: scale)
    case .time: return .nullableTime(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int32>.self).values, mask: mask))
    case .time64(let precision): return .nullableTime64(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int64>.self).values, mask: mask), precision: precision)
    case .int256: return .nullableInt256(applyMask(values: try requireColumn(nullable.inner, ClickHouseInt256Column.self).values, mask: mask))
    case .uint256: return .nullableUInt256(applyMask(values: try requireColumn(nullable.inner, ClickHouseUInt256Column.self).values, mask: mask))
    case .bfloat16: return .nullableBFloat16(applyMask(values: try requireColumn(nullable.inner, ClickHouseBFloat16Column.self).values, mask: mask))
    case .ipv4: return .nullableIPv4(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values, mask: mask))
    case .ipv6: return .nullableIPv6(applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedStringColumn.self).values, mask: mask))
    case .fixedString(let length): return .nullableFixedString(length: length, applyMask(values: try requireColumn(nullable.inner, ClickHouseFixedStringColumn.self).values, mask: mask))
    case .enum8, .enum16, .interval, .json, .nothing, .array, .nullable, .tuple, .map, .lowCardinality:
        throw ClickHouseError.unsupportedSelectColumnType(typeName: nullable.spec.typeName)
    }
}

private func mapNullableDate(nullable: ClickHouseNullableColumn, mask: [Bool]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt16>.self).values
    let dates = raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0)) * 86_400) }
    return .nullableDate(applyMask(values: dates, mask: mask))
}

private func mapNullableDateTime(nullable: ClickHouseNullableColumn, mask: [Bool]) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<UInt32>.self).values
    let dates = raw.map { Date(timeIntervalSince1970: TimeInterval(Int64($0))) }
    return .nullableDateTime(applyMask(values: dates, mask: mask))
}

private func mapNullableDateTime64(nullable: ClickHouseNullableColumn, mask: [Bool], precision: Int) throws -> ClickHouseColumnEntry.Values {
    let raw = try requireColumn(nullable.inner, ClickHouseFixedWidthIntegerColumn<Int64>.self).values
    let multiplier = ClickHouseClient.nanosecondsToColumnDivisor(precision: precision)
    let nanos = try raw.map { tick -> ClickHouseNanoseconds in
        try multiplyTickToNanoseconds(tick: tick, multiplier: multiplier, precision: precision)
    }
    return .nullableDateTime64Nanoseconds(applyMask(values: nanos, mask: mask), precision: precision)
}

private func applyMask<T>(values: [T], mask: [Bool]) -> [ClickHouseNullable<T>] {
    var result: [ClickHouseNullable<T>] = []
    result.reserveCapacity(values.count)
    for index in 0..<values.count {
        result.append(mask[index] ? .absent : .present(values[index]))
    }
    return result
}

private func requireColumn<T: ClickHouseColumn>(_ column: any ClickHouseColumn, _ type: T.Type) throws -> T {
    guard let typed = column as? T else {
        throw ClickHouseError.internalColumnTypeCastFailure(
            typeName: column.spec.typeName,
            expectedType: String(describing: T.self)
        )
    }
    return typed
}
