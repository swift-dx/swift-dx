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

// A value destined for a ClickHouse Time64(precision) column. The wire
// value is the signed tick count, i.e. the number of 10^-precision-second
// units, stored as an 8-byte little-endian Int64. The precision parameter
// mirrors the column declaration `Time64(P)`.
public struct ClickHouseTime64: Sendable, Hashable, Codable {

    public let ticks: Int64
    public let precision: UInt8

    public init(ticks: Int64, precision: UInt8) {
        self.ticks = ticks
        self.precision = precision
    }

    // Builds the tick count from a Swift Duration at the given precision.
    // Throws for a precision the tick scale cannot represent, or for a
    // Duration whose whole-second part overflows the Int64 tick range once
    // scaled to 10^-precision-second units.
    public init(_ duration: Duration, precision: UInt8) throws(ClickHouseError) {
        try Self.validatePrecision(precision)
        let components = duration.components
        self.ticks = try Self.ticks(seconds: components.seconds, attoseconds: components.attoseconds, precision: precision)
        self.precision = precision
    }

    // The signed elapsed time this value represents, as a Swift Duration.
    // Throws for a precision outside the representable range.
    public func duration() throws(ClickHouseError) -> Duration {
        try Self.validatePrecision(precision)
        let scale = Self.powerOfTen(Int(precision))
        return Duration(
            secondsComponent: ticks / scale,
            attosecondsComponent: (ticks % scale) * Self.powerOfTen(18 - Int(precision))
        )
    }

    private static func validatePrecision(_ precision: UInt8) throws(ClickHouseError) {
        guard precision <= 18 else {
            throw .protocolError(stage: "time64", message: "precision \(precision) exceeds the representable Time64 range (0...18)")
        }
    }

    private static func ticks(seconds: Int64, attoseconds: Int64, precision: UInt8) throws(ClickHouseError) -> Int64 {
        let scale = powerOfTen(Int(precision))
        let whole = seconds.multipliedReportingOverflow(by: scale)
        let total = whole.partialValue.addingReportingOverflow(attoseconds / powerOfTen(18 - Int(precision)))
        guard !whole.overflow, !total.overflow else {
            throw .protocolError(stage: "time64", message: "duration overflows the Time64 tick range at precision \(precision)")
        }
        return total.partialValue
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        var result: Int64 = 1
        var remaining = exponent
        while remaining > 0 {
            result *= 10
            remaining -= 1
        }
        return result
    }
}
