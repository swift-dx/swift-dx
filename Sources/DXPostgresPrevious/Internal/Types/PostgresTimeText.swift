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

// Parses the text rendering of `time`/`timetz` (`HH:MM:SS[.ffffff][±HH[:MM]]`)
// into a PostgresTime. The binary path is exact; this covers values returned by
// the simple query protocol, which are always text.
enum PostgresTimeText {

    static func parse(_ text: String) throws(PostgresError) -> PostgresTime {
        var body = Substring(text)
        let offset = extractZone(&body)
        let microseconds = try microseconds(of: body)
        return PostgresTime(microsecondsSinceMidnight: microseconds, zoneOffsetSeconds: Int32(offset))
    }

    private static func extractZone(_ body: inout Substring) -> Int {
        if body.hasSuffix("Z") {
            body = body.dropLast()
            return 0
        }
        guard let signIndex = body.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return 0 }
        let zone = body[signIndex...]
        body = body[..<signIndex]
        return offsetSeconds(zone)
    }

    private static func offsetSeconds(_ zone: Substring) -> Int {
        let parts = zone.dropFirst().split(separator: ":")
        let hours = Int(parts.first ?? "0") ?? 0
        let minutes = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let magnitude = hours * 3600 + minutes * 60
        return zone.hasPrefix("-") ? -magnitude : magnitude
    }

    private static func microseconds(of clock: Substring) throws(PostgresError) -> Int64 {
        let (hms, fractionMicros) = splitFraction(clock)
        let parts = hms.split(separator: ":")
        guard parts.count == 3 else {
            throw PostgresError.typeDecodingFailed(type: "PostgresTime", reason: "malformed time '\(clock)'")
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
            throw PostgresError.typeDecodingFailed(type: "PostgresTime", reason: "non-numeric time component '\(text)'")
        }
        return value
    }
}
