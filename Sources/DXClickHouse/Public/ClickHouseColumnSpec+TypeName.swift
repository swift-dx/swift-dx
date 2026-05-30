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

// Inverse of ClickHouseTypeNameParser: produces the wire-form type-name
// string that `parse(_:)` would re-parse to the same spec. The block
// encoder emits a column's type via this property; correctness of
// that round-trip is a hard invariant — drift here corrupts every
// emitted block.
public extension ClickHouseColumnSpec {

    var typeName: String {
        switch self {
        case .int8: return "Int8"
        case .int16: return "Int16"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .int128: return "Int128"
        case .uint8: return "UInt8"
        case .uint16: return "UInt16"
        case .uint32: return "UInt32"
        case .uint64: return "UInt64"
        case .uint128: return "UInt128"
        case .float32: return "Float32"
        case .float64: return "Float64"
        case .string: return "String"
        case .fixedString(let length): return "FixedString(\(length))"
        case .bool: return "Bool"
        case .uuid: return "UUID"
        case .date: return "Date"
        case .date32: return "Date32"
        case .dateTime(let timezone):
            switch timezone {
            case .serverDefault: return "DateTime"
            case .explicit(let value): return "DateTime(\(Self.quote(value)))"
            }
        case .dateTime64(let precision, let timezone):
            switch timezone {
            case .serverDefault: return "DateTime64(\(precision))"
            case .explicit(let value): return "DateTime64(\(precision), \(Self.quote(value)))"
            }
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .array(let element): return "Array(\(element.typeName))"
        case .nullable(let inner): return "Nullable(\(inner.typeName))"
        case .tuple(let elements):
            let joined = elements.map(\.typeName).joined(separator: ", ")
            return "Tuple(\(joined))"
        case .map(let key, let value):
            return "Map(\(key.typeName), \(value.typeName))"
        case .lowCardinality(let inner):
            return "LowCardinality(\(inner.typeName))"
        case .enum8(let entries):
            let parts = entries.map { "\(Self.quote($0.name)) = \($0.value)" }
            return "Enum8(\(parts.joined(separator: ", ")))"
        case .enum16(let entries):
            let parts = entries.map { "\(Self.quote($0.name)) = \($0.value)" }
            return "Enum16(\(parts.joined(separator: ", ")))"
        case .decimal32(let scale):
            return "Decimal32(\(scale))"
        case .decimal64(let scale):
            return "Decimal64(\(scale))"
        case .decimal128(let scale):
            return "Decimal128(\(scale))"
        case .time: return "Time"
        case .time64(let precision):
            return "Time64(\(precision))"
        case .interval(let kind):
            return kind.typeName
        case .int256: return "Int256"
        case .uint256: return "UInt256"
        case .decimal256(let scale):
            return "Decimal256(\(scale))"
        case .bfloat16: return "BFloat16"
        case .nothing: return "Nothing"
        case .json: return "JSON"
        }
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

}
