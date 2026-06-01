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

// The time unit of a ClickHouse Interval value. Every kind shares the
// same Int64 wire storage; the kind only selects the type-name string the
// server emits and how the server interprets the magnitude. The server
// reports these as PascalCase names like `IntervalDay` and
// `IntervalNanosecond`; `typeName` produces that string and
// `init(typeName:)` parses it back, throwing when the name is not a known
// Interval kind.
public enum ClickHouseIntervalKind: Sendable, Hashable, CaseIterable, Codable {

    case nanosecond
    case microsecond
    case millisecond
    case second
    case minute
    case hour
    case day
    case week
    case month
    case quarter
    case year

    public var typeName: String {
        switch self {
        case .nanosecond: "IntervalNanosecond"
        case .microsecond: "IntervalMicrosecond"
        case .millisecond: "IntervalMillisecond"
        case .second: "IntervalSecond"
        case .minute: "IntervalMinute"
        case .hour: "IntervalHour"
        case .day: "IntervalDay"
        case .week: "IntervalWeek"
        case .month: "IntervalMonth"
        case .quarter: "IntervalQuarter"
        case .year: "IntervalYear"
        }
    }

    static func isKindName(_ typeName: String) -> Bool {
        allCases.contains { $0.typeName == typeName }
    }

    public init(typeName: String) throws(ClickHouseError) {
        switch typeName {
        case "IntervalNanosecond": self = .nanosecond
        case "IntervalMicrosecond": self = .microsecond
        case "IntervalMillisecond": self = .millisecond
        case "IntervalSecond": self = .second
        case "IntervalMinute": self = .minute
        case "IntervalHour": self = .hour
        case "IntervalDay": self = .day
        case "IntervalWeek": self = .week
        case "IntervalMonth": self = .month
        case "IntervalQuarter": self = .quarter
        case "IntervalYear": self = .year
        default:
            throw .protocolError(
                stage: "interval.kind",
                message: "'\(typeName)' is not a ClickHouse Interval kind (expected one of IntervalNanosecond through IntervalYear)"
            )
        }
    }
}
