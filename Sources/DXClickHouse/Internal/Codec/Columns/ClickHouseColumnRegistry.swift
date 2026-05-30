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

enum ClickHouseColumnRegistry {

    // Spec-dispatched dual of the encoder's `encodePrefix`. Consumes
    // ONLY the column-level prefix bytes (the KeysSerializationVersion
    // for LowCardinality; nothing for primitives). Composite specs
    // descend so a nested LowCardinality's version is consumed at the
    // chunk start — before the composite's offsets/null mask — to
    // match CH's two-phase wire layout on both INSERT and SELECT.
    static func decodePrefix(spec: ClickHouseColumnSpec, from buffer: inout ByteBuffer) throws {
        switch spec {
        case .lowCardinality:
            try ClickHouseLowCardinalityColumn.decodePrefix(from: &buffer)
        case .array(let inner), .nullable(let inner):
            try decodePrefix(spec: inner, from: &buffer)
        case .map(let key, let value):
            try decodePrefix(spec: key, from: &buffer)
            try decodePrefix(spec: value, from: &buffer)
        case .tuple(let elements):
            for element in elements {
                try decodePrefix(spec: element, from: &buffer)
            }
        default:
            return
        }
    }

    static func decode(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> any ClickHouseColumn {
        switch spec {
        case .int8:
            return try ClickHouseFixedWidthIntegerColumn<Int8>.decode(spec: spec, rows: rows, from: &buffer)
        case .int16:
            return try ClickHouseFixedWidthIntegerColumn<Int16>.decode(spec: spec, rows: rows, from: &buffer)
        case .int32:
            return try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: spec, rows: rows, from: &buffer)
        case .int64:
            return try ClickHouseFixedWidthIntegerColumn<Int64>.decode(spec: spec, rows: rows, from: &buffer)
        case .int128:
            return try ClickHouseFixedWidthIntegerColumn<Int128>.decode(spec: spec, rows: rows, from: &buffer)
        case .uint8:
            return try ClickHouseFixedWidthIntegerColumn<UInt8>.decode(spec: spec, rows: rows, from: &buffer)
        case .uint16:
            return try ClickHouseFixedWidthIntegerColumn<UInt16>.decode(spec: spec, rows: rows, from: &buffer)
        case .uint32:
            return try ClickHouseFixedWidthIntegerColumn<UInt32>.decode(spec: spec, rows: rows, from: &buffer)
        case .uint64:
            return try ClickHouseFixedWidthIntegerColumn<UInt64>.decode(spec: spec, rows: rows, from: &buffer)
        case .uint128:
            return try ClickHouseFixedWidthIntegerColumn<UInt128>.decode(spec: spec, rows: rows, from: &buffer)
        case .float32:
            return try ClickHouseFloat32Column.decode(rows: rows, from: &buffer)
        case .float64:
            return try ClickHouseFloat64Column.decode(rows: rows, from: &buffer)
        case .string:
            return try ClickHouseStringColumn.decode(spec: .string, rows: rows, from: &buffer)
        case .fixedString(let length):
            return try ClickHouseFixedStringColumn.decode(spec: spec, length: length, rows: rows, from: &buffer)
        case .bool:
            return try ClickHouseBoolColumn.decode(rows: rows, from: &buffer)
        case .uuid:
            return try ClickHouseUUIDColumn.decode(rows: rows, from: &buffer)
        case .date:
            return try ClickHouseFixedWidthIntegerColumn<UInt16>.decode(spec: spec, rows: rows, from: &buffer)
        case .date32:
            return try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: spec, rows: rows, from: &buffer)
        case .dateTime:
            return try ClickHouseFixedWidthIntegerColumn<UInt32>.decode(spec: spec, rows: rows, from: &buffer)
        case .dateTime64:
            return try ClickHouseFixedWidthIntegerColumn<Int64>.decode(spec: spec, rows: rows, from: &buffer)
        case .ipv4:
            return try ClickHouseFixedWidthIntegerColumn<UInt32>.decode(spec: spec, rows: rows, from: &buffer)
        case .ipv6:
            return try ClickHouseFixedStringColumn.decode(spec: spec, length: 16, rows: rows, from: &buffer)
        case .array(let elementSpec):
            return try ClickHouseArrayColumn.decode(elementSpec: elementSpec, rows: rows, from: &buffer)
        case .nullable(let innerSpec):
            return try ClickHouseNullableColumn.decode(innerSpec: innerSpec, rows: rows, from: &buffer)
        case .tuple(let elementSpecs):
            return try ClickHouseTupleColumn.decode(elementSpecs: elementSpecs, rows: rows, from: &buffer)
        case .map(let keySpec, let valueSpec):
            return try ClickHouseMapColumn.decode(keySpec: keySpec, valueSpec: valueSpec, rows: rows, from: &buffer)
        case .lowCardinality(let innerSpec):
            return try ClickHouseLowCardinalityColumn.decode(innerSpec: innerSpec, rows: rows, from: &buffer)
        case .enum8:
            return try ClickHouseFixedWidthIntegerColumn<Int8>.decode(spec: spec, rows: rows, from: &buffer)
        case .enum16:
            return try ClickHouseFixedWidthIntegerColumn<Int16>.decode(spec: spec, rows: rows, from: &buffer)
        case .decimal32:
            return try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: spec, rows: rows, from: &buffer)
        case .decimal64:
            return try ClickHouseFixedWidthIntegerColumn<Int64>.decode(spec: spec, rows: rows, from: &buffer)
        case .decimal128:
            return try ClickHouseFixedWidthIntegerColumn<Int128>.decode(spec: spec, rows: rows, from: &buffer)
        case .time:
            return try ClickHouseFixedWidthIntegerColumn<Int32>.decode(spec: spec, rows: rows, from: &buffer)
        case .time64:
            return try ClickHouseFixedWidthIntegerColumn<Int64>.decode(spec: spec, rows: rows, from: &buffer)
        case .interval:
            return try ClickHouseFixedWidthIntegerColumn<Int64>.decode(spec: spec, rows: rows, from: &buffer)
        case .int256:
            return try ClickHouseInt256Column.decode(spec: spec, rows: rows, from: &buffer)
        case .uint256:
            return try ClickHouseUInt256Column.decode(spec: spec, rows: rows, from: &buffer)
        case .decimal256:
            return try ClickHouseInt256Column.decode(spec: spec, rows: rows, from: &buffer)
        case .bfloat16:
            return try ClickHouseBFloat16Column.decode(spec: spec, rows: rows, from: &buffer)
        case .nothing:
            return try ClickHouseNothingColumn.decode(spec: spec, rows: rows, from: &buffer)
        case .json:
            // Wire format identical to String — JSON values are sent as raw
            // length-prefixed UTF-8. The server parses on insert.
            return try ClickHouseStringColumn.decode(spec: .json, rows: rows, from: &buffer)
        }
    }

}
