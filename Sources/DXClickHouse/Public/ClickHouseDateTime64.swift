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
    //
    // Throws rather than trapping when the date and precision do not fit
    // the Int64 tick domain: a far-future or far-past date at high
    // precision, or an out-of-range precision, would otherwise overflow
    // the Int64 conversion and crash the process inside a public
    // initializer.
    public init(_ date: Date, precision: UInt8 = 9) throws(ClickHouseError) {
        guard precision <= 18 else {
            throw .protocolError(
                stage: "dateTime64",
                message: "DateTime64 precision \(precision) exceeds the maximum of 18"
            )
        }
        let scale = pow(10.0, Double(precision))
        let raw = (date.timeIntervalSince1970 * scale).rounded()
        guard raw.isFinite, raw >= Double(Int64.min), raw < Double(Int64.max) else {
            throw .protocolError(
                stage: "dateTime64",
                message: "date at precision \(precision) is outside the representable DateTime64 tick range"
            )
        }
        self.ticks = Int64(raw)
        self.precision = precision
    }

    public var date: Date {
        let scale = pow(10.0, Double(precision))
        return Date(timeIntervalSince1970: Double(ticks) / scale)
    }
}
