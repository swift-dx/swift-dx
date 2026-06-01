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

// A value destined for a ClickHouse Variant(...) column. `members`
// declares the column's member type set; `value` is this row's chosen
// alternative (or `.null`). ClickHouse normalizes a Variant type string
// by sorting its members alphabetically by type name and assigns each
// member a discriminator equal to its position in that sorted order, so
// `members` is always stored in that canonical sorted order and the row
// discriminator is derived from where `value`'s member sits in it.
//
// The supported member set mirrors `ClickHouseVariantValue`: String,
// Int64, UInt64, Float64. The convenience initializers build the
// canonical member list for the common shapes so callers do not have to
// reason about the sort order themselves.
public struct ClickHouseVariant: Sendable, Hashable, Codable {

    public let members: [ClickHouseArrayElementType]
    public let value: ClickHouseVariantValue

    public init(members: [ClickHouseArrayElementType], value: ClickHouseVariantValue) {
        self.members = members
        self.value = value
    }

    public static func stringOrUInt64(_ value: ClickHouseVariantValue) -> ClickHouseVariant {
        ClickHouseVariant(members: [.string, .uint64], value: value)
    }

    public static func stringOrInt64(_ value: ClickHouseVariantValue) -> ClickHouseVariant {
        ClickHouseVariant(members: [.int64, .string], value: value)
    }
}
