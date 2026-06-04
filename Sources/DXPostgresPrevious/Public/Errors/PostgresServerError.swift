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

/// A structured error reported by the PostgreSQL server in an `ErrorResponse`
/// message. The three fields PostgreSQL guarantees on every error — severity,
/// the five-character SQLSTATE code, and the human-readable primary message —
/// are surfaced as stored properties. Every other field the server chose to
/// include (detail, hint, the offending constraint, the source position, and so
/// on) is queried with ``value(of:)``.
public struct PostgresServerError: Error, Sendable, Equatable {

    struct Field: Sendable, Equatable {

        let code: UInt8
        let value: String
    }

    public let severity: String
    public let sqlState: String
    public let message: String
    let fields: [Field]

    init(severity: String, sqlState: String, message: String, fields: [Field]) {
        self.severity = severity
        self.sqlState = sqlState
        self.message = message
        self.fields = fields
    }

    public init(severity: String, sqlState: String, message: String) {
        self.init(severity: severity, sqlState: sqlState, message: message, fields: [])
    }

    // SQLSTATE classes that mean "the transaction conflicted, retry it":
    // serialization_failure (40001, also YugabyteDB's read-restart) and
    // deadlock_detected (40P01). A single autocommit statement that hits one of
    // these can be safely re-run, so the resilience layer treats it as transient.
    var isRetryable: Bool {
        sqlState == "40001" || sqlState == "40P01"
    }

    /// The text of an optional error field, or ``PostgresFieldValue/absent`` when
    /// the server did not include it. The severity, SQLSTATE code, and primary
    /// message are not looked up here; read them from the stored properties.
    public func value(of code: PostgresErrorFieldCode) -> PostgresFieldValue {
        for field in fields where field.code == code.rawValue {
            return .present(field.value)
        }
        return .absent
    }
}

extension PostgresServerError: CustomStringConvertible {

    public var description: String {
        "\(severity) \(sqlState): \(message)"
    }
}
