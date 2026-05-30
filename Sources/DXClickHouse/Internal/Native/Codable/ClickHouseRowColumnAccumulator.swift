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

// Internal column accumulator. Each column is one of these — a
// typed buffer that enforces "first row sets the type" semantics.
//
// Each case stores a `ClickHouseRowColumnBuffer<T>` reference rather
// than a raw `[T]`. The reference wrapper is the load-bearing
// detail: when an enum case holds an `[T]` directly, every
// pattern-matched `var arr` rebinding inside a dictionary's
// `recordKeyAndAppend` keeps the original buffer reference alive
// alongside the local binding, so `arr.append(value)` fails the
// unique-reference test and copies the entire column on every
// single append — turning insert into O(rows^2). Routing the array
// through a class reference makes the mutation in-place inside the
// class's stored property, where Swift can prove uniqueness, and
// restores O(rows) behavior.
enum ClickHouseRowColumnAccumulator {

    case string(ClickHouseRowColumnBuffer<String>)
    case bool(ClickHouseRowColumnBuffer<Bool>)
    case int8(ClickHouseRowColumnBuffer<Int8>)
    case int16(ClickHouseRowColumnBuffer<Int16>)
    case int32(ClickHouseRowColumnBuffer<Int32>)
    case int64(ClickHouseRowColumnBuffer<Int64>)
    case uint8(ClickHouseRowColumnBuffer<UInt8>)
    case uint16(ClickHouseRowColumnBuffer<UInt16>)
    case uint32(ClickHouseRowColumnBuffer<UInt32>)
    case uint64(ClickHouseRowColumnBuffer<UInt64>)
    case float32(ClickHouseRowColumnBuffer<Float>)
    case float64(ClickHouseRowColumnBuffer<Double>)
    case dateTime(ClickHouseRowColumnBuffer<Date>)
    case uuid(ClickHouseRowColumnBuffer<UUID>)
    case mapStringString(ClickHouseRowColumnBuffer<[String: String]>)

    case nullableString(ClickHouseRowColumnBuffer<ClickHouseNullable<String>>)
    case nullableBool(ClickHouseRowColumnBuffer<ClickHouseNullable<Bool>>)
    case nullableInt8(ClickHouseRowColumnBuffer<ClickHouseNullable<Int8>>)
    case nullableInt16(ClickHouseRowColumnBuffer<ClickHouseNullable<Int16>>)
    case nullableInt32(ClickHouseRowColumnBuffer<ClickHouseNullable<Int32>>)
    case nullableInt64(ClickHouseRowColumnBuffer<ClickHouseNullable<Int64>>)
    case nullableUInt8(ClickHouseRowColumnBuffer<ClickHouseNullable<UInt8>>)
    case nullableUInt16(ClickHouseRowColumnBuffer<ClickHouseNullable<UInt16>>)
    case nullableUInt32(ClickHouseRowColumnBuffer<ClickHouseNullable<UInt32>>)
    case nullableUInt64(ClickHouseRowColumnBuffer<ClickHouseNullable<UInt64>>)
    case nullableFloat32(ClickHouseRowColumnBuffer<ClickHouseNullable<Float>>)
    case nullableFloat64(ClickHouseRowColumnBuffer<ClickHouseNullable<Double>>)
    case nullableDateTime(ClickHouseRowColumnBuffer<ClickHouseNullable<Date>>)
    case nullableUUID(ClickHouseRowColumnBuffer<ClickHouseNullable<UUID>>)

    var rowCount: Int {
        switch self {
        case .string(let v): return v.values.count
        case .bool(let v): return v.values.count
        case .int8(let v): return v.values.count
        case .int16(let v): return v.values.count
        case .int32(let v): return v.values.count
        case .int64(let v): return v.values.count
        case .uint8(let v): return v.values.count
        case .uint16(let v): return v.values.count
        case .uint32(let v): return v.values.count
        case .uint64(let v): return v.values.count
        case .float32(let v): return v.values.count
        case .float64(let v): return v.values.count
        case .dateTime(let v): return v.values.count
        case .uuid(let v): return v.values.count
        case .mapStringString(let v): return v.values.count
        case .nullableString(let v): return v.values.count
        case .nullableBool(let v): return v.values.count
        case .nullableInt8(let v): return v.values.count
        case .nullableInt16(let v): return v.values.count
        case .nullableInt32(let v): return v.values.count
        case .nullableInt64(let v): return v.values.count
        case .nullableUInt8(let v): return v.values.count
        case .nullableUInt16(let v): return v.values.count
        case .nullableUInt32(let v): return v.values.count
        case .nullableUInt64(let v): return v.values.count
        case .nullableFloat32(let v): return v.values.count
        case .nullableFloat64(let v): return v.values.count
        case .nullableDateTime(let v): return v.values.count
        case .nullableUUID(let v): return v.values.count
        }
    }

    var typeName: String {
        switch self {
        case .string: return "String"
        case .bool: return "Bool"
        case .int8: return "Int8"
        case .int16: return "Int16"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .uint8: return "UInt8"
        case .uint16: return "UInt16"
        case .uint32: return "UInt32"
        case .uint64: return "UInt64"
        case .float32: return "Float"
        case .float64: return "Double"
        case .dateTime: return "Date"
        case .uuid: return "UUID"
        case .mapStringString: return "[String: String]"
        case .nullableString: return "String?"
        case .nullableBool: return "Bool?"
        case .nullableInt8: return "Int8?"
        case .nullableInt16: return "Int16?"
        case .nullableInt32: return "Int32?"
        case .nullableInt64: return "Int64?"
        case .nullableUInt8: return "UInt8?"
        case .nullableUInt16: return "UInt16?"
        case .nullableUInt32: return "UInt32?"
        case .nullableUInt64: return "UInt64?"
        case .nullableFloat32: return "Float?"
        case .nullableFloat64: return "Double?"
        case .nullableDateTime: return "Date?"
        case .nullableUUID: return "UUID?"
        }
    }

    func toValues() -> ClickHouseColumnEntry.Values {
        switch self {
        case .string(let v): return .string(v.values)
        case .bool(let v): return .bool(v.values)
        case .int8(let v): return .int8(v.values)
        case .int16(let v): return .int16(v.values)
        case .int32(let v): return .int32(v.values)
        case .int64(let v): return .int64(v.values)
        case .uint8(let v): return .uint8(v.values)
        case .uint16(let v): return .uint16(v.values)
        case .uint32(let v): return .uint32(v.values)
        case .uint64(let v): return .uint64(v.values)
        case .float32(let v): return .float32(v.values)
        case .float64(let v): return .float64(v.values)
        case .dateTime(let v): return .dateTime(v.values)
        case .uuid(let v): return .uuid(v.values)
        case .mapStringString(let v): return .mapStringString(v.values)
        case .nullableString(let v): return .nullableString(v.values)
        case .nullableBool(let v): return .nullableBool(v.values)
        case .nullableInt8(let v): return .nullableInt8(v.values)
        case .nullableInt16(let v): return .nullableInt16(v.values)
        case .nullableInt32(let v): return .nullableInt32(v.values)
        case .nullableInt64(let v): return .nullableInt64(v.values)
        case .nullableUInt8(let v): return .nullableUInt8(v.values)
        case .nullableUInt16(let v): return .nullableUInt16(v.values)
        case .nullableUInt32(let v): return .nullableUInt32(v.values)
        case .nullableUInt64(let v): return .nullableUInt64(v.values)
        case .nullableFloat32(let v): return .nullableFloat32(v.values)
        case .nullableFloat64(let v): return .nullableFloat64(v.values)
        case .nullableDateTime(let v): return .nullableDateTime(v.values)
        case .nullableUUID(let v): return .nullableUUID(v.values)
        }
    }

}

// Reference-typed buffer wrapper that lets the encoder mutate a
// column's underlying array in place without paying CoW on every
// append. The buffer is created when its column is first observed
// and lives in the storage's by-name dictionary for the lifetime
// of the encode pass.
final class ClickHouseRowColumnBuffer<Element> {

    var values: [Element]

    init() {
        self.values = []
    }

    init(reservingCapacity capacity: Int) {
        self.values = []
        self.values.reserveCapacity(capacity)
    }

}
