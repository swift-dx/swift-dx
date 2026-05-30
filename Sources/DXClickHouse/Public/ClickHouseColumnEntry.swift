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

// One column to INSERT, in column-major form. `name` is the
// destination column name; `values` is the typed-array union
// holding all rows for that column. Bundle these into an array
// and pass to `client.insert(into:columns:)`. The same `Values`
// enum is reused on the SELECT side via `ClickHouseSelectColumn`,
// so a column that round-trips through ClickHouse comes back in
// the same case it went in.
public struct ClickHouseColumnEntry: Sendable {

    public enum Values: Sendable {

        case int8([Int8])
        case int16([Int16])
        case int32([Int32])
        case int64([Int64])
        case int128([Int128])
        case uint8([UInt8])
        case uint16([UInt16])
        case uint32([UInt32])
        case uint64([UInt64])
        case uint128([UInt128])
        case float32([Float32])
        case float64([Float64])
        case string([String])
        case bool([Bool])
        case uuid([UUID])
        case date([Date])
        case date32([Date])
        case dateTime([Date])
        case dateTime64([Date], precision: Int)
        case fixedString(length: Int, [Data])
        case arrayOfString([[String]])
        case arrayOfInt32([[Int32]])
        case arrayOfInt64([[Int64]])
        case arrayOfUInt32([[UInt32]])
        case arrayOfUInt64([[UInt64]])
        case nullableString([ClickHouseNullable<String>])
        case nullableInt32([ClickHouseNullable<Int32>])
        case nullableInt64([ClickHouseNullable<Int64>])
        case nullableUInt32([ClickHouseNullable<UInt32>])
        case nullableUInt64([ClickHouseNullable<UInt64>])
        case mapStringString([[String: String]])
        case ipv4([UInt32])
        case ipv6([Data])
        case lowCardinalityString([String])
        case decimal32([Int32], scale: Int)
        case decimal64([Int64], scale: Int)
        case decimal128([Int128], scale: Int)
        case nullableUUID([ClickHouseNullable<UUID>])
        case nullableDate([ClickHouseNullable<Date>])
        case nullableDateTime([ClickHouseNullable<Date>])
        case nullableBool([ClickHouseNullable<Bool>])
        case arrayOfUUID([[UUID]])
        case arrayOfBool([[Bool]])
        case mapStringInt32([[String: Int32]])
        case mapStringInt64([[String: Int64]])
        case arrayOfFloat32([[Float32]])
        case arrayOfFloat64([[Float64]])
        case arrayOfDate([[Date]])
        case arrayOfDateTime([[Date]])
        case nullableFloat64([ClickHouseNullable<Float64>])
        case tupleStringString([(String, String)])
        case tupleStringInt32([(String, Int32)])
        case tupleStringInt64([(String, Int64)])
        case tupleFloat64Float64([(Double, Double)])
        case time([Int32])
        case time64([Int64], precision: Int)
        case interval(kind: ClickHouseIntervalKind, values: [Int64])
        case int256([ClickHouseInt256])
        case uint256([ClickHouseUInt256])
        case decimal256([ClickHouseInt256], scale: Int)
        case bfloat16([ClickHouseBFloat16])
        case json([String])
        case nullableInt8([ClickHouseNullable<Int8>])
        case nullableInt16([ClickHouseNullable<Int16>])
        case nullableUInt8([ClickHouseNullable<UInt8>])
        case nullableUInt16([ClickHouseNullable<UInt16>])
        case nullableFloat32([ClickHouseNullable<Float32>])
        case mapStringFloat64([[String: Double]])
        case mapStringBool([[String: Bool]])
        case mapInt32String([[Int32: String]])
        case mapInt64String([[Int64: String]])
        case arrayOfInt8([[Int8]])
        case arrayOfInt16([[Int16]])
        case arrayOfUInt8([[UInt8]])
        case arrayOfUInt16([[UInt16]])
        case arrayOfBFloat16([[ClickHouseBFloat16]])
        case arrayOfTupleFloat64Float64([[(Double, Double)]])
        case arrayOfArrayOfTupleFloat64Float64([[[(Double, Double)]]])
        case arrayOfArrayOfArrayOfTupleFloat64Float64([[[[(Double, Double)]]]])
        case nullableDecimal32([ClickHouseNullable<Int32>], scale: Int)
        case nullableDecimal64([ClickHouseNullable<Int64>], scale: Int)
        case nullableDecimal128([ClickHouseNullable<Int128>], scale: Int)
        case nullableDecimal256([ClickHouseNullable<ClickHouseInt256>], scale: Int)
        case nullableDate32([ClickHouseNullable<Int32>])
        case nullableDateTime64([ClickHouseNullable<Int64>], precision: Int)
        case nullableInt128([ClickHouseNullable<Int128>])
        case nullableUInt128([ClickHouseNullable<UInt128>])
        case nullableInt256([ClickHouseNullable<ClickHouseInt256>])
        case nullableUInt256([ClickHouseNullable<ClickHouseUInt256>])
        case nullableTime([ClickHouseNullable<Int32>])
        case nullableTime64([ClickHouseNullable<Int64>], precision: Int)
        case nullableBFloat16([ClickHouseNullable<ClickHouseBFloat16>])
        case dateTime64Nanoseconds([ClickHouseNanoseconds], precision: Int)
        case nullableDateTime64Nanoseconds([ClickHouseNullable<ClickHouseNanoseconds>], precision: Int)
        case mapStringFloat32([[String: Float32]])
        case mapStringUUID([[String: UUID]])
        case mapStringDateTime([[String: Date]])
        case mapUInt64Int64([[UInt64: Int64]])
        case nullableIPv4([ClickHouseNullable<UInt32>])
        case nullableIPv6([ClickHouseNullable<Data>])
        case nullableFixedString(length: Int, [ClickHouseNullable<Data>])
        case lowCardinalityStringIndexed(ClickHouseLowCardinalityStringView)
        case mapStringStringIndexed(ClickHouseMapStringStringStorage)

    }

    public let name: String
    public let values: Values

    public init(name: String, values: Values) {
        self.name = name
        self.values = values
    }

}
