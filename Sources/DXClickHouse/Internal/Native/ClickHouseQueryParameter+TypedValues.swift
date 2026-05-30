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

// Typed factory constructors that match the common ClickHouse parameter
// types in `{name:Type}` SQL placeholder syntax. Every factory wraps
// the value in single-quoted Field-literal form because the server's
// `BaseSettings::read` calls `Field::restoreFromDump` on the wire
// value: only the String-Field dump format `'value'` is accepted at
// that call site, and the server then coerces to the SQL-declared
// `:Type`. Without the quotes every numeric/bool/uuid/date parameter
// throws `Couldn't restore Field from dump: <raw>` server-side.
extension ClickHouseQueryParameter {

    // Wrap a raw string in the Field-literal `'value'` form with
    // backslash-escaped embedded quotes. Used by every typed factory
    // that produces a value the server must then coerce to a non-
    // String SQL type.
    private static func quote(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    public static func int8(_ value: Int8, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func int16(_ value: Int16, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func int32(_ value: Int32, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func int64(_ value: Int64, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func int128(_ value: Int128, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func uint8(_ value: UInt8, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func uint16(_ value: UInt16, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func uint32(_ value: UInt32, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func uint64(_ value: UInt64, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func uint128(_ value: UInt128, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func float32(_ value: Float32, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    public static func float64(_ value: Float64, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(String(value)))
    }

    // Strings already need the Field-literal form for their own type;
    // this factory does the same quoting+escaping the helper does.
    public static func string(_ value: String, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(value))
    }

    // Server expects `true` / `false` (lowercase) for `:Bool` parameters.
    public static func bool(_ value: Bool, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(value ? "true" : "false"))
    }

    // UUIDs are formatted as the canonical lowercase 8-4-4-4-12 hex
    // string; the server's `:UUID` parser is case-insensitive but
    // documented in lowercase, matching `UUID().description`.
    public static func uuid(_ value: UUID, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(value.uuidString.lowercased()))
    }

    // Formats as `YYYY-MM-DD` in UTC. The server's `:Date` parser
    // interprets the literal as UTC; if the underlying column carries
    // a timezone (rare for Date), it is the storage layer that
    // re-interprets, not this client.
    public static func date(_ value: Date, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(clickhouseDateFormatter.string(from: value)))
    }

    // Formats as `YYYY-MM-DD HH:MM:SS` (whole seconds) in UTC. Matches
    // the server's storage convention for `:DateTime` parameters.
    public static func dateTime(_ value: Date, name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: quote(clickhouseDateTimeFormatter.string(from: value)))
    }

    // Formats as `YYYY-MM-DD HH:MM:SS.f...` in UTC, with `precision`
    // fractional digits (0-9). Use 3 for milliseconds, 6 for
    // microseconds, 9 for nanoseconds. The server's `:DateTime64`
    // parser truncates extra digits but accepts fewer than the column's
    // declared precision.
    //
    // PRECISION CAVEAT: `Date` is a 64-bit `Double` of seconds since
    // reference. At year-2024 timestamps (~1.7e9 seconds) the machine
    // epsilon is ~4e-7, so this method is lossy past microseconds.
    // For true nanosecond precision use `dateTime64Ticks(_:name:precision:)`
    // which takes raw Int64 ticks and round-trips losslessly.
    public static func dateTime64(_ value: Date, name: String, precision: Int) -> ClickHouseQueryParameter {
        let secondsPart = clickhouseDateTimeFormatter.string(from: value)
        guard precision > 0 else {
            return .init(name: name, value: quote(secondsPart))
        }
        // The formatter floors the calendar second toward -infinity
        // (which is what "the second containing T" means). For a pre-
        // 1970 Date like -100.7s (= 1969-12-31T23:58:19.3 UTC) it
        // emits "1969-12-31 23:58:19" — the same second that 0.3s of
        // fractional belongs to. wholeSeconds MUST use the same floor
        // direction or the fractional silently shifts by 1 second
        // and the wire literal corrupts pre-epoch timestamps. Pre-fix
        // this used `.towardZero` + `abs(...)`, which agreed with the
        // formatter for non-negative timestamps but disagreed for
        // negative ones (off-by-(1-fractional) seconds).
        let totalSeconds = value.timeIntervalSince1970
        let wholeSeconds = totalSeconds.rounded(.down)
        let fractional = totalSeconds - wholeSeconds
        let multiplier = pow(10.0, Double(precision))
        // Round to nearest, not toward zero: Double can't represent
        // 0.3 exactly (it stores 0.2999999999...), so
        // `(0.3 * 1000).rounded(.towardZero)` yielded 299 instead of
        // 300. Nearest-rounding recovers the user's intended fraction
        // for inputs near a precision boundary while still truncating
        // genuine over-precision (e.g., 0.3009 at precision 3 rounds
        // to 301, the closest representable millisecond, matching
        // user expectation for "round to nearest representable").
        let scaledFraction = Int64((fractional * multiplier).rounded(.toNearestOrEven))
        let formattedFraction = String(format: "%0*lld", precision, scaledFraction)
        return .init(name: name, value: quote("\(secondsPart).\(formattedFraction)"))
    }

    // Nanosecond-faithful DateTime64 parameter at precision 9.
    // Wraps `dateTime64Ticks` with `precision: 9`. Use this when you
    // already have a `ClickHouseNanoseconds` value and the target
    // column is `DateTime64(9)`.
    public static func dateTime64Nanoseconds(_ value: ClickHouseNanoseconds, name: String) -> ClickHouseQueryParameter {
        dateTime64Ticks(value.rawValue, name: name, precision: 9)
    }

    // Lossless DateTime64 parameter for nanosecond-precision use cases.
    // `ticks` is the raw integer at the column's `precision` (e.g.
    // 1_700_000_000_500_000_001 for 2023-11-14 22:13:20.500000001 at
    // precision 9). The same Int64 representation that flows through
    // the column codec, so SELECT → re-INSERT round-trips with no
    // precision loss.
    //
    // This is the path to use when full nanosecond fidelity matters.
    // The `Date`-based `dateTime64(_:name:precision:)` is more
    // ergonomic but bound by Double precision (~microsecond at
    // year-2024 timestamps).
    public static func dateTime64Ticks(_ ticks: Int64, name: String, precision: Int) -> ClickHouseQueryParameter {
        guard precision > 0 else {
            return .init(name: name, value: quote(String(ticks)))
        }
        let scale: Int64 = pow10(precision)
        // Floor-divide ticks by scale: Swift's `/` on signed integers
        // truncates toward zero, but the calendar-string format requires
        // the fractional part to be in [0, scale). Without this
        // adjustment, ticks = -1 (1ns before epoch at precision 9) would
        // produce wholeSeconds = 0, fractional = -1, and the wire literal
        // would read "1970-01-01 00:00:00.000000001" (1ns AFTER epoch),
        // silently corrupting any pre-1970 timestamp passed in via raw
        // ticks.
        var wholeSeconds = ticks / scale
        var fractional = ticks % scale
        if fractional < 0 {
            wholeSeconds -= 1
            fractional += scale
        }
        let secondsPart = clickhouseDateTimeFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        )
        let formattedFraction = String(format: "%0*lld", precision, fractional)
        return .init(name: name, value: quote("\(secondsPart).\(formattedFraction)"))
    }

}

private func pow10(_ exponent: Int) -> Int64 {
    var result: Int64 = 1
    for _ in 0..<exponent { result *= 10 }
    return result
}

extension ClickHouseQueryParameter {

    // Array(Int8/16/32/64) parameters: format `[v1,v2,...,vN]` with no
    // spaces. Empty array becomes `[]`. Server parses each element
    // according to the declared inner type.
    public static func arrayInt8(_ values: [Int8], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayInt16(_ values: [Int16], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayInt32(_ values: [Int32], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayInt64(_ values: [Int64], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayUInt8(_ values: [UInt8], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayUInt16(_ values: [UInt16], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayUInt32(_ values: [UInt32], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayUInt64(_ values: [UInt64], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayFloat32(_ values: [Float32], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayFloat64(_ values: [Float64], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayBool(_ values: [Bool], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values, format: { $0 ? "true" : "false" }))
    }

    // Array(String) needs each element single-quoted with embedded
    // `'` and `\` escaped so the server's parser can round-trip the
    // original content. Delegates to the same `quote` helper the
    // scalar `string` factory uses, so any escape rule change happens
    // in one place.
    public static func arrayString(_ values: [String], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values, format: quote))
    }

    // UUID values use a constrained alphabet (hex + hyphens) so the
    // single-quoted form needs no further escaping.
    public static func arrayUUID(_ values: [UUID], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values, format: { "'\($0.uuidString.lowercased())'" }))
    }

    // Array(Date) parameters: each element single-quoted in `'YYYY-MM-DD'`
    // UTC format. Server-side `:Array(Date)` parses each literal.
    public static func arrayDate(_ values: [Date], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { "'\(clickhouseDateFormatter.string(from: $0))'" })
    }

    // Array(DateTime) parameters: each element single-quoted in
    // `'YYYY-MM-DD HH:MM:SS'` UTC format with whole-second resolution.
    public static func arrayDateTime(_ values: [Date], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { "'\(clickhouseDateTimeFormatter.string(from: $0))'" })
    }

    // Array(Int128) and Array(UInt128) for wide integer keys. Native
    // Swift Int128/UInt128 have decimal-string conversion via String.init,
    // so no scaling logic is needed.
    public static func arrayInt128(_ values: [Int128], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

    public static func arrayUInt128(_ values: [UInt128], name: String) -> ClickHouseQueryParameter {
        .init(name: name, value: joinArrayLiteral(values) { String($0) })
    }

}

private func joinArrayLiteral<T>(_ values: [T], format: (T) -> String) -> String {
    "[\(values.map(format).joined(separator: ","))]"
}

// File-scope cached formatters — DateFormatter init is expensive
// (~1ms) so the factory methods would be hot if they re-allocated.
private let clickhouseDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let clickhouseDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()
