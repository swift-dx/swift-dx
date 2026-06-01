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

// A value destined for a ClickHouse Date column. The wire value is the
// unsigned number of days since the Unix epoch (1970-01-01), stored as a
// 2-byte little-endian UInt16. Use this type instead of `Date` when the
// column is declared `Date`; a plain `Date` maps to second-resolution
// `DateTime`.
public struct ClickHouseDate: Sendable, Hashable, Codable {

    public let days: UInt16

    public init(days: UInt16) {
        self.days = days
    }
}
