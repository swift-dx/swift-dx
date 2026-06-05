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

// The element type carried by a ClickHouse Array(...) column. Supports
// String, FixedString(N), the fixed-width numeric scalars, and the temporal
// types DateTime / Date / Date32. Nested arrays, Nullable, and
// LowCardinality element types are not supported.
public enum ClickHouseArrayElementType: Sendable, Hashable, Codable {

    case string
    case fixedString(length: Int)
    case bool
    case int8
    case int16
    case int32
    case int64
    case uint8
    case uint16
    case uint32
    case uint64
    case float32
    case float64
    case dateTime
    case date
    case date32
    case dateTime64(precision: UInt8)
    case decimal(precision: UInt8, scale: UInt8)
    case enum8(mapping: [ClickHouseEnumPair])
    case enum16(mapping: [ClickHouseEnumPair])
    case uuid
    case ipv4
    case ipv6
    case int128
    case uint128
    case int256
    case uint256
}

extension ClickHouseArrayElementType {

    var typeName: String {
        switch self {
        case .string: "String"
        case .fixedString(let length): "FixedString(\(length))"
        case .bool: "Bool"
        case .int8: "Int8"
        case .int16: "Int16"
        case .int32: "Int32"
        case .int64: "Int64"
        case .uint8: "UInt8"
        case .uint16: "UInt16"
        case .uint32: "UInt32"
        case .uint64: "UInt64"
        case .float32: "Float32"
        case .float64: "Float64"
        case .dateTime: "DateTime"
        case .date: "Date"
        case .date32: "Date32"
        case .dateTime64(let precision): "DateTime64(\(precision))"
        case .decimal(let precision, let scale): "Decimal(\(precision), \(scale))"
        case .enum8(let mapping): "Enum8(\(ClickHouseEnumMapping.render(mapping)))"
        case .enum16(let mapping): "Enum16(\(ClickHouseEnumMapping.render(mapping)))"
        case .uuid: "UUID"
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .int128: "Int128"
        case .uint128: "UInt128"
        case .int256: "Int256"
        case .uint256: "UInt256"
        }
    }

    // Per-element wire width in bytes; -1 marks the variable-width,
    // length-prefixed String element.
    var fixedWidth: Int {
        switch self {
        case .string: -1
        case .fixedString(let length): length
        case .bool: 1
        case .int8, .uint8: 1
        case .int16, .uint16: 2
        case .int32, .uint32, .float32: 4
        case .int64, .uint64, .float64: 8
        case .dateTime, .date32: 4
        case .date: 2
        case .dateTime64: 8
        case .decimal(let precision, _): ClickHouseDecimalWidth.bytes(forPrecision: precision)
        case .enum8: 1
        case .enum16: 2
        case .uuid: 16
        case .ipv4: 4
        case .ipv6: 16
        case .int128, .uint128: 16
        case .int256, .uint256: 32
        }
    }
}
