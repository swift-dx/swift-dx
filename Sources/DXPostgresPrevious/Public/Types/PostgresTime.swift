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

/// A PostgreSQL `time` or `timetz` value: a time of day with microsecond
/// resolution, independent of any calendar date. `zoneOffsetSeconds` is the UTC
/// offset for `timetz` and zero for `time`. The Swift standard library has no
/// time-of-day type, so this carries the wire representation and exposes the
/// component fields.
public struct PostgresTime: Sendable, Equatable {

    public let microsecondsSinceMidnight: Int64
    public let zoneOffsetSeconds: Int32

    public init(microsecondsSinceMidnight: Int64, zoneOffsetSeconds: Int32 = 0) {
        self.microsecondsSinceMidnight = microsecondsSinceMidnight
        self.zoneOffsetSeconds = zoneOffsetSeconds
    }

    public var hour: Int {
        Int(microsecondsSinceMidnight / 3_600_000_000)
    }

    public var minute: Int {
        Int((microsecondsSinceMidnight / 60_000_000) % 60)
    }

    public var second: Int {
        Int((microsecondsSinceMidnight / 1_000_000) % 60)
    }

    public var microsecond: Int {
        Int(microsecondsSinceMidnight % 1_000_000)
    }
}

extension PostgresTime: CustomStringConvertible {

    public var description: String {
        let base = String(format: "%02d:%02d:%02d", hour, minute, second)
        return microsecond == 0 ? base : base + String(format: ".%06d", microsecond)
    }
}
