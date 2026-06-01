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

// Parses PostgreSQL's default interval text output ("1 year 2 mons 3 days
// 04:05:06[.ffffff]", with signs) into a PostgresInterval. Numeric-unit pairs
// accumulate into months/days/microseconds and the clock component into
// microseconds. The binary path is exact; this covers the simple query protocol.
enum PostgresIntervalText {

    static func parse(_ text: String) throws(PostgresError) -> PostgresInterval {
        var months: Int32 = 0
        var days: Int32 = 0
        var microseconds: Int64 = 0
        let tokens = text.split(separator: " ")
        var index = 0
        while index < tokens.count {
            try absorb(tokens, index: &index, months: &months, days: &days, microseconds: &microseconds)
        }
        return PostgresInterval(months: months, days: days, microseconds: microseconds)
    }

    private static func absorb(_ tokens: [Substring], index: inout Int, months: inout Int32, days: inout Int32, microseconds: inout Int64) throws(PostgresError) {
        let token = tokens[index]
        guard !token.contains(":") else {
            microseconds += try clockMicroseconds(token)
            index += 1
            return
        }
        try absorbUnit(tokens, index: &index, months: &months, days: &days, microseconds: &microseconds)
    }

    private static func absorbUnit(_ tokens: [Substring], index: inout Int, months: inout Int32, days: inout Int32, microseconds: inout Int64) throws(PostgresError) {
        guard index + 1 < tokens.count else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInterval", reason: "dangling amount '\(tokens[index])'")
        }
        let amount = try integer(tokens[index])
        applyUnit(tokens[index + 1], amount: amount, months: &months, days: &days, microseconds: &microseconds)
        index += 2
    }

    private static func applyUnit(_ unit: Substring, amount: Int, months: inout Int32, days: inout Int32, microseconds: inout Int64) {
        switch true {
        case unit.hasPrefix("year"): months += Int32(amount * 12)
        case unit.hasPrefix("mon"): months += Int32(amount)
        case unit.hasPrefix("day"): days += Int32(amount)
        case unit.hasPrefix("hour"): microseconds += Int64(amount) * 3_600_000_000
        case unit.hasPrefix("min"): microseconds += Int64(amount) * 60_000_000
        case unit.hasPrefix("sec"): microseconds += Int64(amount) * 1_000_000
        default: break
        }
    }

    private static func clockMicroseconds(_ token: Substring) throws(PostgresError) -> Int64 {
        guard token.hasPrefix("-") else { return try positiveClockMicroseconds(token) }
        return try -positiveClockMicroseconds(token.dropFirst())
    }

    private static func positiveClockMicroseconds(_ body: Substring) throws(PostgresError) -> Int64 {
        let (hms, fractionMicros) = splitFraction(body)
        let parts = hms.split(separator: ":")
        guard parts.count == 3 else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInterval", reason: "malformed clock '\(body)'")
        }
        let seconds = try integer(parts[0]) * 3600 + integer(parts[1]) * 60 + integer(parts[2])
        return Int64(seconds) * 1_000_000 + Int64(fractionMicros)
    }

    private static func splitFraction(_ text: Substring) -> (clock: Substring, micros: Int) {
        guard let dotIndex = text.firstIndex(of: ".") else { return (text, 0) }
        let fraction = text[text.index(after: dotIndex)...]
        return (text[..<dotIndex], Int((fraction + "000000").prefix(6)) ?? 0)
    }

    private static func integer(_ text: Substring) throws(PostgresError) -> Int {
        guard let value = Int(text) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInterval", reason: "non-numeric interval amount '\(text)'")
        }
        return value
    }
}
