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

/// A SQL statement whose interpolated values are bound parameters, not text
/// spliced into the SQL. Written as a string literal with interpolations:
///
/// ```swift
/// let statement: PostgresStatement = "SELECT id FROM users WHERE email = \(email) AND active = \(true)"
/// ```
///
/// Each `\(value)` becomes a `$1`, `$2`, … placeholder and the value is sent as a
/// parameter over the extended protocol, so a value can never be interpreted as
/// SQL. A plain string literal with no interpolations is a statement with no
/// parameters.
public struct PostgresStatement: Sendable, ExpressibleByStringInterpolation {

    let sql: String
    let bindings: [PostgresCell]

    public init(stringLiteral value: String) {
        self.sql = value
        self.bindings = []
    }

    public init(stringInterpolation: Interpolation) {
        self.sql = stringInterpolation.sql
        self.bindings = stringInterpolation.bindings
    }

    public struct Interpolation: StringInterpolationProtocol {

        var sql = ""
        var bindings: [PostgresCell] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            sql.reserveCapacity(literalCapacity + interpolationCount * 3)
            bindings.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            sql += literal
        }

        public mutating func appendInterpolation(_ value: Int) { bind(String(value)) }
        public mutating func appendInterpolation(_ value: Int64) { bind(String(value)) }
        public mutating func appendInterpolation(_ value: Int32) { bind(String(value)) }
        public mutating func appendInterpolation(_ value: Double) { bind(String(value)) }
        public mutating func appendInterpolation(_ value: String) { bind(value) }
        public mutating func appendInterpolation(_ value: Bool) { bind(value ? "t" : "f") }
        public mutating func appendInterpolation(_ value: [UInt8]) { bind("\\x" + value.map { String(format: "%02x", $0) }.joined()) }

        /// Splices a single SQL identifier (a schema, table, or column name) into
        /// the statement as literal SQL rather than a bound parameter, because a
        /// parameter placeholder can only stand for a value, never an identifier.
        /// The name is wrapped in double quotes and any embedded double quote is
        /// doubled, so it is always parsed as one identifier and can never be read
        /// as SQL syntax. Quote each component of a qualified name separately:
        /// `"SELECT * FROM \(identifier: schema).\(identifier: table)"`.
        public mutating func appendInterpolation(identifier: String) {
            sql += PostgresIdentifier.quoted(identifier)
        }

        private mutating func bind(_ text: String) {
            bindings.append(.bytes(Array(text.utf8)))
            sql += "$\(bindings.count)"
        }
    }
}
