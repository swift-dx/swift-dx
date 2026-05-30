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

// ClickHouse Interval type kind — selects the time unit. Each kind
// shares the same Int64 wire storage; the kind only affects the
// type-name string and how the server interprets the value (e.g.,
// `IntervalDay(7)` is 7 days, `IntervalNanosecond(7)` is 7 ns).
//
// Server-emitted type names are PascalCase concatenations:
// `IntervalYear`, `IntervalQuarter`, etc. The `name` property below
// produces the matching string; `init(typeName:)` is the inverse.
public enum ClickHouseIntervalKind: Sendable, Hashable, CaseIterable {

    case year
    case quarter
    case month
    case week
    case day
    case hour
    case minute
    case second
    case millisecond
    case microsecond
    case nanosecond

    public var typeName: String {
        switch self {
        case .year: return "IntervalYear"
        case .quarter: return "IntervalQuarter"
        case .month: return "IntervalMonth"
        case .week: return "IntervalWeek"
        case .day: return "IntervalDay"
        case .hour: return "IntervalHour"
        case .minute: return "IntervalMinute"
        case .second: return "IntervalSecond"
        case .millisecond: return "IntervalMillisecond"
        case .microsecond: return "IntervalMicrosecond"
        case .nanosecond: return "IntervalNanosecond"
        }
    }

    public init?(typeName: String) {
        switch typeName {
        case "IntervalYear": self = .year
        case "IntervalQuarter": self = .quarter
        case "IntervalMonth": self = .month
        case "IntervalWeek": self = .week
        case "IntervalDay": self = .day
        case "IntervalHour": self = .hour
        case "IntervalMinute": self = .minute
        case "IntervalSecond": self = .second
        case "IntervalMillisecond": self = .millisecond
        case "IntervalMicrosecond": self = .microsecond
        case "IntervalNanosecond": self = .nanosecond
        default: return nil
        }
    }

}
