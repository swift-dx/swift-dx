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

// Discriminated union of typed in-memory column buffers supported by
// the DXClickHouse Codable layer. Each case carries a flat Swift
// array of values plus the ClickHouse type-name string that the wire
// layer emits when writing the block, and that the SELECT path matches
// against to pick the right decode branch.
//
// Supported set:
//   * String, Bool
//   * Int8/16/32/64, UInt8/16/32/64
//   * Float (Float32), Double (Float64)
//   * Foundation.Date  (DateTime, 4-byte seconds-since-epoch)
//   * Foundation.UUID  (UUID, 16-byte little-endian halves)
//   * Nullable variants for every supported scalar
//
// The cases are ordered to keep related variants together so adding a
// new scalar type touches one bucket only.
package enum ClickHouseTypedColumn: Sendable {

    case string([[UInt8]])
    // Encode-only String column carrying native Swift strings, serialized by
    // streaming each value's utf8 view straight to the wire. The `.string`
    // ([[UInt8]]) variant is what decode produces and forces every value into a
    // separate heap array up front; for the columnar insert fast path that
    // materialization is the dominant cost, so this variant defers it. Both
    // serialize to the identical String wire format.
    case stringValues([String])
    case nullableString([ClickHouseNullable<[UInt8]>])

    case bool([Bool])
    case nullableBool([ClickHouseNullable<Bool>])

    case int8([Int8])
    case int16([Int16])
    case int32([Int32])
    case int64([Int64])
    case nullableInt8([ClickHouseNullable<Int8>])
    case nullableInt16([ClickHouseNullable<Int16>])
    case nullableInt32([ClickHouseNullable<Int32>])
    case nullableInt64([ClickHouseNullable<Int64>])

    case uint8([UInt8])
    case uint16([UInt16])
    case uint32([UInt32])
    case uint64([UInt64])
    case nullableUInt8([ClickHouseNullable<UInt8>])
    case nullableUInt16([ClickHouseNullable<UInt16>])
    case nullableUInt32([ClickHouseNullable<UInt32>])
    case nullableUInt64([ClickHouseNullable<UInt64>])

    case float32([Float])
    case float64([Double])
    case nullableFloat32([ClickHouseNullable<Float>])
    case nullableFloat64([ClickHouseNullable<Double>])

    case dateTime([Date])
    case nullableDateTime([ClickHouseNullable<Date>])

    case uuid([UUID])
    case nullableUUID([ClickHouseNullable<UUID>])

    case dateTime64([Int64], precision: UInt8)
    case date([UInt16])
    case time([Int32])
    case time64([Int64], precision: UInt8)
    case fixedString([[UInt8]], length: Int)
    case enum8([Int8], mapping: [ClickHouseEnumPair])
    case enum16([Int16], mapping: [ClickHouseEnumPair])
    case lowCardinality([[UInt8]], inner: ClickHouseLowCardinalityInner)
    case array([[[UInt8]]], element: ClickHouseArrayElementType)
    case date32([Int32])
    case bfloat16([UInt16])
    case ipv4([UInt32])
    case ipv6([[UInt8]])
    case int128([Int128])
    case uint128([UInt128])
    case int256([ClickHouseInt256])
    case uint256([ClickHouseUInt256])
    case json([[UInt8]])
    case decimal([ClickHouseDecimal], precision: UInt8, scale: UInt8)
    case interval([Int64], kind: ClickHouseIntervalKind)
    case nothing(rowCount: Int)

    indirect case tuple([ClickHouseTypedColumn], names: [String])

    case map(keys: [[[UInt8]]], values: [[[UInt8]]], keyElement: ClickHouseArrayElementType, valueElement: ClickHouseArrayElementType)

    case mapWithNullableValues(keys: [[[UInt8]]], values: [[ClickHouseNullable<[UInt8]>]], keyElement: ClickHouseArrayElementType, valueElement: ClickHouseArrayElementType)

    case mapWithArrayValues(keys: [[[UInt8]]], values: [[[[UInt8]]]], keyElement: ClickHouseArrayElementType, valueElement: ClickHouseArrayElementType)

    case arrayOfTuple(elementValues: [[[[UInt8]]]], elements: [ClickHouseArrayElementType], names: [String])

    case arrayOfNullable(perRow: [[ClickHouseNullable<[UInt8]>]], element: ClickHouseArrayElementType)

    case nestedArray(perRow: [[[[UInt8]]]], element: ClickHouseArrayElementType)

    case variant(members: [ClickHouseArrayElementType], discriminators: [UInt8], values: [[UInt8]])

    case dynamic(members: [ClickHouseArrayElementType], discriminators: [UInt8], values: [[UInt8]])

    case aggregateFunction(signature: String, states: [[UInt8]])

    indirect case nullable(mask: [Bool], inner: ClickHouseTypedColumn)

    package func isNull(at row: Int) -> Bool {
        switch self {
        case .nullableBool(let values): values[row].isAbsent
        case .nullableString(let values): values[row].isAbsent
        case .nullableInt8(let values): values[row].isAbsent
        case .nullableInt16(let values): values[row].isAbsent
        case .nullableInt32(let values): values[row].isAbsent
        case .nullableInt64(let values): values[row].isAbsent
        case .nullableUInt8(let values): values[row].isAbsent
        case .nullableUInt16(let values): values[row].isAbsent
        case .nullableUInt32(let values): values[row].isAbsent
        case .nullableUInt64(let values): values[row].isAbsent
        case .nullableFloat32(let values): values[row].isAbsent
        case .nullableFloat64(let values): values[row].isAbsent
        case .nullableDateTime(let values): values[row].isAbsent
        case .nullableUUID(let values): values[row].isAbsent
        case .nullable(let mask, _): mask[row]
        default: false
        }
    }

    package var rowCount: Int {
        switch self {
        case .string(let values): values.count
        case .stringValues(let values): values.count
        case .nullableString(let values): values.count
        case .bool(let values): values.count
        case .nullableBool(let values): values.count
        case .int8(let values): values.count
        case .int16(let values): values.count
        case .int32(let values): values.count
        case .int64(let values): values.count
        case .nullableInt8(let values): values.count
        case .nullableInt16(let values): values.count
        case .nullableInt32(let values): values.count
        case .nullableInt64(let values): values.count
        case .uint8(let values): values.count
        case .uint16(let values): values.count
        case .uint32(let values): values.count
        case .uint64(let values): values.count
        case .nullableUInt8(let values): values.count
        case .nullableUInt16(let values): values.count
        case .nullableUInt32(let values): values.count
        case .nullableUInt64(let values): values.count
        case .float32(let values): values.count
        case .float64(let values): values.count
        case .nullableFloat32(let values): values.count
        case .nullableFloat64(let values): values.count
        case .dateTime(let values): values.count
        case .nullableDateTime(let values): values.count
        case .uuid(let values): values.count
        case .nullableUUID(let values): values.count
        case .dateTime64(let values, _): values.count
        case .date(let values): values.count
        case .time(let values): values.count
        case .time64(let values, _): values.count
        case .fixedString(let values, _): values.count
        case .enum8(let values, _): values.count
        case .enum16(let values, _): values.count
        case .lowCardinality(let values, _): values.count
        case .array(let values, _): values.count
        case .date32(let values): values.count
        case .bfloat16(let values): values.count
        case .ipv4(let values): values.count
        case .ipv6(let values): values.count
        case .int128(let values): values.count
        case .uint128(let values): values.count
        case .int256(let values): values.count
        case .uint256(let values): values.count
        case .json(let values): values.count
        case .decimal(let values, _, _): values.count
        case .interval(let values, _): values.count
        case .nothing(let rowCount): rowCount
        case .tuple(let columns, _): Self.tupleRowCount(columns)
        case .map(let keys, _, _, _): keys.count
        case .mapWithNullableValues(let keys, _, _, _): keys.count
        case .mapWithArrayValues(let keys, _, _, _): keys.count
        case .arrayOfTuple(let elementValues, _, _): elementValues.isEmpty ? 0 : elementValues[0].count
        case .arrayOfNullable(let perRow, _): perRow.count
        case .nestedArray(let perRow, _): perRow.count
        case .variant(_, let discriminators, _): discriminators.count
        case .dynamic(_, let discriminators, _): discriminators.count
        case .aggregateFunction(_, let states): states.count
        case .nullable(let mask, _): mask.count
        }
    }

    private static func tupleRowCount(_ columns: [ClickHouseTypedColumn]) -> Int {
        guard let first = columns.first else { return 0 }
        return first.rowCount
    }

    package var typeName: String {
        switch self {
        case .string: "String"
        case .stringValues: "String"
        case .nullableString: "Nullable(String)"
        case .bool: "Bool"
        case .nullableBool: "Nullable(Bool)"
        case .int8: "Int8"
        case .int16: "Int16"
        case .int32: "Int32"
        case .int64: "Int64"
        case .nullableInt8: "Nullable(Int8)"
        case .nullableInt16: "Nullable(Int16)"
        case .nullableInt32: "Nullable(Int32)"
        case .nullableInt64: "Nullable(Int64)"
        case .uint8: "UInt8"
        case .uint16: "UInt16"
        case .uint32: "UInt32"
        case .uint64: "UInt64"
        case .nullableUInt8: "Nullable(UInt8)"
        case .nullableUInt16: "Nullable(UInt16)"
        case .nullableUInt32: "Nullable(UInt32)"
        case .nullableUInt64: "Nullable(UInt64)"
        case .float32: "Float32"
        case .float64: "Float64"
        case .nullableFloat32: "Nullable(Float32)"
        case .nullableFloat64: "Nullable(Float64)"
        case .dateTime: "DateTime"
        case .nullableDateTime: "Nullable(DateTime)"
        case .uuid: "UUID"
        case .nullableUUID: "Nullable(UUID)"
        case .dateTime64(_, let precision): "DateTime64(\(precision))"
        case .date: "Date"
        case .time: "Time"
        case .time64(_, let precision): "Time64(\(precision))"
        case .fixedString(_, let length): "FixedString(\(length))"
        case .enum8(_, let mapping): "Enum8(\(ClickHouseEnumMapping.render(mapping)))"
        case .enum16(_, let mapping): "Enum16(\(ClickHouseEnumMapping.render(mapping)))"
        case .lowCardinality(_, let inner): "LowCardinality(\(inner.typeName))"
        case .array(_, let element): "Array(\(element.typeName))"
        case .date32: "Date32"
        case .bfloat16: "BFloat16"
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .int128: "Int128"
        case .uint128: "UInt128"
        case .int256: "Int256"
        case .uint256: "UInt256"
        case .json: "String"
        case .decimal(_, let precision, let scale): "Decimal(\(precision), \(scale))"
        case .interval(_, let kind): kind.typeName
        case .nothing: "Nothing"
        case .tuple(let columns, let names): "Tuple(\(ClickHouseTupleTypeName.render(columns: columns, names: names)))"
        case .map(_, _, let keyElement, let valueElement): "Map(\(keyElement.typeName), \(valueElement.typeName))"
        case .mapWithNullableValues(_, _, let keyElement, let valueElement): "Map(\(keyElement.typeName), Nullable(\(valueElement.typeName)))"
        case .mapWithArrayValues(_, _, let keyElement, let valueElement): "Map(\(keyElement.typeName), Array(\(valueElement.typeName)))"
        case .arrayOfTuple(_, let elements, _): "Array(Tuple(\(elements.map(\.typeName).joined(separator: ", "))))"
        case .arrayOfNullable(_, let element): "Array(Nullable(\(element.typeName)))"
        case .nestedArray(_, let element): "Array(Array(\(element.typeName)))"
        case .variant(let members, _, _): "Variant(\(ClickHouseVariantTypeName.render(members)))"
        case .dynamic: "Dynamic"
        case .aggregateFunction(let signature, _): "AggregateFunction(\(signature))"
        case .nullable(_, let inner): "Nullable(\(inner.typeName))"
        }
    }
}
