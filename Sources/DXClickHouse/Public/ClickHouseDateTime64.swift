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

// A value destined for a ClickHouse DateTime64(precision) column. Use a
// field of this type on a Codable row instead of `Date` when the column
// stores sub-second ticks; a plain `Date` maps to second-resolution
// `DateTime`. The wire value is the signed tick count, i.e. the number of
// 10^-precision-second units since the Unix epoch.
public struct ClickHouseDateTime64: Sendable, Hashable, Codable {

    public let ticks: Int64
    public let precision: UInt8

    public init(ticks: Int64, precision: UInt8) {
        self.ticks = ticks
        self.precision = precision
    }

    // Convenience that derives ticks from a `Date`. Because `Date` stores
    // a `Double` seconds value, ticks beyond `Date`'s own resolution
    // (roughly sub-microsecond for present-day instants) are not exact;
    // for true nanosecond fidelity supply an `Int64` via init(ticks:).
    public init(_ date: Date, precision: UInt8 = 9) {
        let scale = pow(10.0, Double(precision))
        self.ticks = Int64((date.timeIntervalSince1970 * scale).rounded())
        self.precision = precision
    }

    public var date: Date {
        let scale = pow(10.0, Double(precision))
        return Date(timeIntervalSince1970: Double(ticks) / scale)
    }
}
