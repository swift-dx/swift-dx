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

// Parses PostgreSQL's ISO datestyle text rendering of date/time values into a
// Foundation `Date` (an absolute instant). Handles "YYYY-MM-DD",
// "YYYY-MM-DD HH:MM:SS", an optional ".ffffff" fractional second, and an optional
// "+HH", "+HH:MM", or "Z" timezone. A value without a timezone is read as UTC.
// The binary path (PostgresBinaryDecoding.temporal) is the fast, exact route; this
// covers the simple query protocol, which always returns text.
enum PostgresTimestampText {

    static func parse(_ text: String) throws(PostgresError) -> Date {
        let halves = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let datePart = halves.first else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "empty timestamp text")
        }
        let date = try parseDate(datePart)
        let timeAndZone = halves.count > 1 ? halves[1] : ""
        return try assemble(date: date, timeAndZone: timeAndZone)
    }

    private static func parseDate(_ text: Substring) throws(PostgresError) -> (year: Int, month: Int, day: Int) {
        let parts = text.split(separator: "-")
        guard parts.count == 3 else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "malformed date '\(text)'")
        }
        return (try integer(parts[0]), try integer(parts[1]), try integer(parts[2]))
    }

    private static func assemble(date: (year: Int, month: Int, day: Int), timeAndZone: Substring) throws(PostgresError) -> Date {
        guard !timeAndZone.isEmpty else {
            return try makeDate(date: date, hour: 0, minute: 0, second: 0, nanosecond: 0, offsetSeconds: 0)
        }
        let (timeText, offsetSeconds) = try splitZone(timeAndZone)
        let (clockText, nanosecond) = splitFraction(timeText)
        let clock = try parseClock(clockText)
        return try makeDate(date: date, hour: clock.hour, minute: clock.minute, second: clock.second, nanosecond: nanosecond, offsetSeconds: offsetSeconds)
    }

    private static func parseClock(_ text: Substring) throws(PostgresError) -> (hour: Int, minute: Int, second: Int) {
        let parts = text.split(separator: ":")
        guard parts.count == 3 else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "malformed time '\(text)'")
        }
        return (try integer(parts[0]), try integer(parts[1]), try integer(parts[2]))
    }

    private static func splitZone(_ text: Substring) throws(PostgresError) -> (time: Substring, offsetSeconds: Int) {
        if text.hasSuffix("Z") { return (text.dropLast(), 0) }
        guard let signIndex = text.lastIndex(where: { $0 == "+" || $0 == "-" }) else {
            return (text, 0)
        }
        return (text[..<signIndex], try parseOffsetSeconds(text[signIndex...]))
    }

    private static func parseOffsetSeconds(_ zone: Substring) throws(PostgresError) -> Int {
        let parts = zone.dropFirst().split(separator: ":")
        guard let hoursText = parts.first else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "malformed timezone '\(zone)'")
        }
        let magnitude = try offsetMagnitude(hoursText: hoursText, parts: parts)
        return zone.hasPrefix("-") ? -magnitude : magnitude
    }

    private static func offsetMagnitude(hoursText: Substring, parts: [Substring]) throws(PostgresError) -> Int {
        let minutes = parts.count > 1 ? try integer(parts[1]) : 0
        return try integer(hoursText) * 3600 + minutes * 60
    }

    private static func splitFraction(_ text: Substring) -> (clock: Substring, nanosecond: Int) {
        guard let dotIndex = text.firstIndex(of: ".") else { return (text, 0) }
        let fraction = text[text.index(after: dotIndex)...]
        return (text[..<dotIndex], nanoseconds(from: fraction))
    }

    private static func nanoseconds(from fraction: Substring) -> Int {
        Int((fraction + "000000000").prefix(9)) ?? 0
    }

    private static func makeDate(date: (year: Int, month: Int, day: Int), hour: Int, minute: Int, second: Int, nanosecond: Int, offsetSeconds: Int) throws(PostgresError) -> Date {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        components.timeZone = TimeZone(secondsFromGMT: 0)
        guard let wallClock = Calendar(identifier: .gregorian).date(from: components) else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "out-of-range date components")
        }
        return wallClock.addingTimeInterval(-Double(offsetSeconds))
    }

    private static func integer(_ text: Substring) throws(PostgresError) -> Int {
        guard let value = Int(text) else {
            throw PostgresError.typeDecodingFailed(type: "Date", reason: "non-numeric date component '\(text)'")
        }
        return value
    }
}
