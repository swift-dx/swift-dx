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

// Server-side substitution parameter for a single query. Referenced in
// the SQL via the `{name:Type}` syntax that ClickHouse parses (e.g.
// `SELECT * FROM t WHERE id = {id:UInt64}`). The server validates the
// value against the declared type, providing SQL-injection-safe
// parameter substitution.
//
// The wire format reuses the Setting (name, flags, value) triple, but
// the flags field is always Custom (bit 1) for parameters.
public struct ClickHouseQueryParameter: Sendable, Equatable {

    public let name: String
    public let value: String

    // The raw value is transmitted verbatim and the server reconstructs it with
    // `Field::restoreFromDump`, so `value` must already be a ClickHouse field
    // dump — a single-quoted, escaped literal for a String (e.g. `'o\'hara'`),
    // the bare digits for an integer. Passing an unescaped raw string fails the
    // query with "Couldn't restore Field from dump". Prefer the typed factories
    // (e.g. `.string(name:value:)`) which produce the correct dump; reach for
    // this initializer only to supply a pre-formatted dump directly.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    // Binds a Swift String to a `{name:String}` placeholder, producing the
    // single-quoted ClickHouse field dump the server expects. Backslash and
    // single-quote are escaped so the value cannot terminate the literal early —
    // an arbitrary string, including one carrying quotes or a `DROP TABLE`
    // payload, is bound as data and returned verbatim, never executed.
    public static func string(name: String, value: String) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(value))
    }

    public static func uint64(name: String, value: UInt64) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(String(value)))
    }

    public static func int64(name: String, value: Int64) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(String(value)))
    }

    public static func int(name: String, value: Int) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(String(value)))
    }

    public static func double(name: String, value: Double) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(String(value)))
    }

    public static func bool(name: String, value: Bool) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(value ? "true" : "false"))
    }

    // ClickHouse renders UUIDs in canonical lowercase; emit the same form so the
    // bound literal matches the server's textual representation, though the parse
    // is case-insensitive and binds the same 128-bit value either way.
    public static func uuid(name: String, value: UUID) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(value.uuidString.lowercased()))
    }

    // Binds an absolute instant as its Unix epoch-second count. The server reads a
    // numeric DateTime literal as seconds since the Unix epoch in UTC, so the same
    // value resolves to the same instant regardless of the column's timezone —
    // unlike a wall-clock string such as "2025-01-15 13:45:30", which the server
    // interprets in the column timezone and would silently shift a time-range
    // boundary by the offset. Sub-second precision is truncated to whole seconds
    // to match DateTime's one-second resolution. The epoch is emitted through the
    // same quoted-dump path as the other factories; the server's numeric-string
    // recognition resolves it as an instant for the DateTime range (from 1970).
    public static func dateTime(name: String, value: Date) -> ClickHouseQueryParameter {
        ClickHouseQueryParameter(name: name, value: dumpedLiteral(String(Int(value.timeIntervalSince1970))))
    }

    // The server decodes a parameter value in two passes: it first restores it as
    // a field dump (un-quoting the literal and undoing dump-string escapes), then
    // parses that result as escaped tab-separated text (where a bare tab or newline
    // ends the value and a dangling backslash is an error) and converts it to the
    // declared `{name:Type}`. The value must survive both passes, so it is escaped
    // twice: once for the escaped-text pass (tabs, newlines, carriage returns,
    // nulls, and backslashes become escape sequences) and again for the field-dump
    // pass (the backslashes produced by the first escape, plus the single-quote
    // that would close the literal, are escaped a second time). Numeric and boolean
    // text contains none of these characters, so for them the escaping is inert and
    // the result is simply the value wrapped in single quotes, which the server
    // converts to the target numeric or boolean type.
    private static func dumpedLiteral(_ value: String) -> String {
        let textEscaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\u{00}", with: "\\0")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let dumpEscaped = textEscaped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(dumpEscaped)'"
    }
}
