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

// A value destined for a ClickHouse Dynamic column. Unlike Variant, a
// Dynamic column does not declare its member type set in the type string:
// the set of concrete types present is discovered from the data and
// serialized inside the column body at write time. `value` is this row's
// concrete alternative (or `.null`); the column's member set is derived
// from the distinct value kinds across all rows of the column.
//
// The supported member set mirrors `ClickHouseVariantValue`: String,
// Int64, UInt64, Float64, plus the `.null` case for an absent row. The
// closed enum gives callers an exhaustively-checked value surface; adding
// a member case later is the documented, accepted SemVer cost.
public struct ClickHouseDynamic: Sendable, Hashable, Codable {

    public let value: ClickHouseVariantValue

    public init(_ value: ClickHouseVariantValue) {
        self.value = value
    }

    public static func string(_ text: String) -> ClickHouseDynamic {
        ClickHouseDynamic(.string(text))
    }

    public static func int64(_ number: Int64) -> ClickHouseDynamic {
        ClickHouseDynamic(.int64(number))
    }

    public static func uint64(_ number: UInt64) -> ClickHouseDynamic {
        ClickHouseDynamic(.uint64(number))
    }

    public static func float64(_ number: Double) -> ClickHouseDynamic {
        ClickHouseDynamic(.float64(number))
    }

    public static let null = ClickHouseDynamic(.null)
}
