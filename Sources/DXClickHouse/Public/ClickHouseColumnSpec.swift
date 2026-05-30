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

// Recursive type metadata for every ClickHouse column. New cases are added
// as type support is wired up — composite cases (Array, Tuple, Map,
// Nullable, LowCardinality), Decimal*, Enum*, Int128/UInt128 join here as
// their codecs land. Timezone on DateTime / DateTime64 is type-name
// metadata only and never appears on the wire; `.serverDefault` defers
// to the server's session timezone, `.explicit("Pacific/Auckland")`
// pins a specific IANA zone name. The precision on DateTime64 is the
// power-of-ten ticks-per-second exponent (0...9); it likewise lives in
// the spec, not the wire bytes.
public indirect enum ClickHouseColumnSpec: Sendable, Hashable {

    case int8
    case int16
    case int32
    case int64
    case int128
    case uint8
    case uint16
    case uint32
    case uint64
    case uint128
    case float32
    case float64
    case string
    case fixedString(length: Int)
    case bool
    case uuid
    case date
    case date32
    case dateTime(timezone: ClickHouseTimezone)
    case dateTime64(precision: Int, timezone: ClickHouseTimezone)
    case ipv4
    case ipv6
    case array(of: ClickHouseColumnSpec)
    case nullable(of: ClickHouseColumnSpec)
    case tuple(elements: [ClickHouseColumnSpec])
    case map(key: ClickHouseColumnSpec, value: ClickHouseColumnSpec)
    case lowCardinality(of: ClickHouseColumnSpec)
    case enum8([ClickHouseEnumValue<Int8>])
    case enum16([ClickHouseEnumValue<Int16>])
    case decimal32(scale: Int)
    case decimal64(scale: Int)
    case decimal128(scale: Int)
    case time
    case time64(precision: Int)
    case interval(kind: ClickHouseIntervalKind)
    case int256
    case uint256
    case decimal256(scale: Int)
    case bfloat16
    case nothing
    case json

}
