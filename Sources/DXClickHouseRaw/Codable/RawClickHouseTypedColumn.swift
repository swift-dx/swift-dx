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
// the DXClickHouseRaw Codable layer. Each case carries a flat Swift
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
public enum RawClickHouseTypedColumn: Sendable {

    case string([String])
    case nullableString([RawClickHouseNullable<String>])

    case bool([Bool])
    case nullableBool([RawClickHouseNullable<Bool>])

    case int8([Int8])
    case int16([Int16])
    case int32([Int32])
    case int64([Int64])
    case nullableInt8([RawClickHouseNullable<Int8>])
    case nullableInt16([RawClickHouseNullable<Int16>])
    case nullableInt32([RawClickHouseNullable<Int32>])
    case nullableInt64([RawClickHouseNullable<Int64>])

    case uint8([UInt8])
    case uint16([UInt16])
    case uint32([UInt32])
    case uint64([UInt64])
    case nullableUInt8([RawClickHouseNullable<UInt8>])
    case nullableUInt16([RawClickHouseNullable<UInt16>])
    case nullableUInt32([RawClickHouseNullable<UInt32>])
    case nullableUInt64([RawClickHouseNullable<UInt64>])

    case float32([Float])
    case float64([Double])
    case nullableFloat32([RawClickHouseNullable<Float>])
    case nullableFloat64([RawClickHouseNullable<Double>])

    case dateTime([Date])
    case nullableDateTime([RawClickHouseNullable<Date>])

    case uuid([UUID])
    case nullableUUID([RawClickHouseNullable<UUID>])

    public var rowCount: Int {
        switch self {
        case .string(let values): values.count
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
        }
    }

    public var typeName: String {
        switch self {
        case .string: "String"
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
        }
    }
}

// One named column in a block: the field name as it appears in the
// destination table (or the SELECT projection) plus the typed value
// buffer.
public struct RawClickHouseNamedColumn: Sendable {

    public let name: String
    public let column: RawClickHouseTypedColumn

    public init(name: String, column: RawClickHouseTypedColumn) {
        self.name = name
        self.column = column
    }
}
