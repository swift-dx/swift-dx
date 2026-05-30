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

// Single source of truth for "how many rows are in this column". The
// row decoder storage uses this to validate that every column shares
// the same row count before constructing rows; without an exhaustive
// switch a missing case would silently report 0, which downstream
// looks like "no rows in the result set" — a silent-data-loss bug.
//
// Internal extension on the public Values: the property isn't part
// of the public API surface, but the compiler still enforces case
// exhaustiveness so adding a new Values variant forces an update
// here at compile time.
extension ClickHouseColumnEntry.Values {

    var rowCount: Int {
        switch self {
        case .int8(let v): return v.count
        case .int16(let v): return v.count
        case .int32(let v): return v.count
        case .int64(let v): return v.count
        case .int128(let v): return v.count
        case .uint8(let v): return v.count
        case .uint16(let v): return v.count
        case .uint32(let v): return v.count
        case .uint64(let v): return v.count
        case .uint128(let v): return v.count
        case .float32(let v): return v.count
        case .float64(let v): return v.count
        case .string(let v): return v.count
        case .bool(let v): return v.count
        case .uuid(let v): return v.count
        case .date(let v): return v.count
        case .date32(let v): return v.count
        case .dateTime(let v): return v.count
        case .dateTime64(let v, _): return v.count
        case .fixedString(_, let v): return v.count
        case .arrayOfString(let v): return v.count
        case .arrayOfInt32(let v): return v.count
        case .arrayOfInt64(let v): return v.count
        case .arrayOfUInt32(let v): return v.count
        case .arrayOfUInt64(let v): return v.count
        case .nullableString(let v): return v.count
        case .nullableInt32(let v): return v.count
        case .nullableInt64(let v): return v.count
        case .nullableUInt32(let v): return v.count
        case .nullableUInt64(let v): return v.count
        case .mapStringString(let v): return v.count
        case .ipv4(let v): return v.count
        case .ipv6(let v): return v.count
        case .lowCardinalityString(let v): return v.count
        case .decimal32(let v, _): return v.count
        case .decimal64(let v, _): return v.count
        case .decimal128(let v, _): return v.count
        case .nullableUUID(let v): return v.count
        case .nullableDate(let v): return v.count
        case .nullableDateTime(let v): return v.count
        case .nullableBool(let v): return v.count
        case .arrayOfUUID(let v): return v.count
        case .arrayOfBool(let v): return v.count
        case .mapStringInt32(let v): return v.count
        case .mapStringInt64(let v): return v.count
        case .arrayOfFloat32(let v): return v.count
        case .arrayOfFloat64(let v): return v.count
        case .arrayOfDate(let v): return v.count
        case .arrayOfDateTime(let v): return v.count
        case .nullableFloat64(let v): return v.count
        case .tupleStringString(let v): return v.count
        case .tupleStringInt32(let v): return v.count
        case .tupleStringInt64(let v): return v.count
        case .tupleFloat64Float64(let v): return v.count
        case .time(let v): return v.count
        case .time64(let v, _): return v.count
        case .interval(_, let v): return v.count
        case .int256(let v): return v.count
        case .uint256(let v): return v.count
        case .decimal256(let v, _): return v.count
        case .bfloat16(let v): return v.count
        case .json(let v): return v.count
        case .nullableInt8(let v): return v.count
        case .nullableInt16(let v): return v.count
        case .nullableUInt8(let v): return v.count
        case .nullableUInt16(let v): return v.count
        case .nullableFloat32(let v): return v.count
        case .mapStringFloat64(let v): return v.count
        case .mapStringBool(let v): return v.count
        case .mapInt32String(let v): return v.count
        case .mapInt64String(let v): return v.count
        case .arrayOfInt8(let v): return v.count
        case .arrayOfInt16(let v): return v.count
        case .arrayOfUInt8(let v): return v.count
        case .arrayOfUInt16(let v): return v.count
        case .arrayOfBFloat16(let v): return v.count
        case .arrayOfTupleFloat64Float64(let v): return v.count
        case .arrayOfArrayOfTupleFloat64Float64(let v): return v.count
        case .arrayOfArrayOfArrayOfTupleFloat64Float64(let v): return v.count
        case .nullableDecimal32(let v, _): return v.count
        case .nullableDecimal64(let v, _): return v.count
        case .nullableDecimal128(let v, _): return v.count
        case .nullableDecimal256(let v, _): return v.count
        case .nullableDate32(let v): return v.count
        case .nullableDateTime64(let v, _): return v.count
        case .nullableInt128(let v): return v.count
        case .nullableUInt128(let v): return v.count
        case .nullableInt256(let v): return v.count
        case .nullableUInt256(let v): return v.count
        case .nullableTime(let v): return v.count
        case .nullableTime64(let v, _): return v.count
        case .nullableBFloat16(let v): return v.count
        case .dateTime64Nanoseconds(let v, _): return v.count
        case .nullableDateTime64Nanoseconds(let v, _): return v.count
        case .mapStringFloat32(let v): return v.count
        case .mapStringUUID(let v): return v.count
        case .mapStringDateTime(let v): return v.count
        case .mapUInt64Int64(let v): return v.count
        case .nullableIPv4(let v): return v.count
        case .nullableIPv6(let v): return v.count
        case .nullableFixedString(_, let v): return v.count
        case .lowCardinalityStringIndexed(let v): return v.count
        case .mapStringStringIndexed(let v): return v.count
        }
    }

}
