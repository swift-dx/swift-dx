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

// A value destined for a ClickHouse Date32 column. The wire value is the
// signed number of days since the Unix epoch (1970-01-01); negative days
// reach back before the epoch.
public struct ClickHouseDate32: Sendable, Hashable, Codable {

    public let days: Int32

    public init(days: Int32) {
        self.days = days
    }

    // Builds the day count from a Foundation Date by flooring its
    // days-since-epoch (the time of day is dropped). Pre-epoch instants
    // become negative day counts. Throws only for instants beyond the Int32
    // day range (far past any value ClickHouse Date32 accepts).
    public init(_ date: Date) throws(ClickHouseError) {
        let days = (date.timeIntervalSince1970 / 86_400).rounded(.down)
        guard (Double(Int32.min)...Double(Int32.max)).contains(days) else {
            throw .protocolError(stage: "date32", message: "date \(date) is outside the Date32 day range")
        }
        self.days = Int32(days)
    }

    // The midnight-UTC instant of this calendar day (negative day counts
    // reach before the epoch).
    public var date: Date {
        Date(timeIntervalSince1970: Double(days) * 86_400)
    }
}
