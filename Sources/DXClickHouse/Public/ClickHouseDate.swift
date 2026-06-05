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

    // Builds the day count from a Foundation Date by flooring its
    // days-since-epoch; the time of day is dropped (a Date column is
    // day-resolution). Throws for instants outside the UInt16 range
    // (1970-01-01 .. 2149-06-06), which a Date column cannot store.
    public init(_ date: Date) throws(ClickHouseError) {
        let days = (date.timeIntervalSince1970 / 86_400).rounded(.down)
        guard (0...Double(UInt16.max)).contains(days) else {
            throw .protocolError(stage: "date", message: "date \(date) is outside the Date range 1970-01-01..2149-06-06")
        }
        self.days = UInt16(days)
    }

    // The midnight-UTC instant of this calendar day.
    public var date: Date {
        Date(timeIntervalSince1970: Double(days) * 86_400)
    }
}
