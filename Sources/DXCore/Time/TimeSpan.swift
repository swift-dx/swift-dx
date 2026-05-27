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

public struct TimeSpan: Sendable, Hashable, Comparable {

    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static func nanoseconds(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount)
    }

    public static func microseconds(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount &* 1_000)
    }

    public static func milliseconds(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount &* 1_000_000)
    }

    public static func seconds(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount &* 1_000_000_000)
    }

    public static func minutes(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount &* 60 &* 1_000_000_000)
    }

    public static func hours(_ amount: Int64) -> TimeSpan {
        TimeSpan(nanoseconds: amount &* 3_600 &* 1_000_000_000)
    }

    public var microseconds: Int64 { nanoseconds / 1_000 }
    public var milliseconds: Int64 { nanoseconds / 1_000_000 }
    public var seconds: Int64 { nanoseconds / 1_000_000_000 }
    public var minutes: Int64 { nanoseconds / 60_000_000_000 }
    public var hours: Int64 { nanoseconds / 3_600_000_000_000 }

    public var fractionalSeconds: Double { Double(nanoseconds) / 1_000_000_000 }

    public static func < (lhs: TimeSpan, rhs: TimeSpan) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}
