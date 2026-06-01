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
// String, FixedString(N), and the fixed-width numeric scalars. Nested
// arrays, Nullable, and LowCardinality element types are not supported.
public enum ClickHouseArrayElementType: Sendable, Hashable, Codable {

    case string
    case fixedString(length: Int)
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
}

extension ClickHouseArrayElementType {

    var typeName: String {
        switch self {
        case .string: "String"
        case .fixedString(let length): "FixedString(\(length))"
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
        }
    }

    // Per-element wire width in bytes; -1 marks the variable-width,
    // length-prefixed String element.
    var fixedWidth: Int {
        switch self {
        case .string: -1
        case .fixedString(let length): length
        case .int8, .uint8: 1
        case .int16, .uint16: 2
        case .int32, .uint32, .float32: 4
        case .int64, .uint64, .float64: 8
        }
    }
}
