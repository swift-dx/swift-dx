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

// Turns the raw (field-code, value) pairs of an ErrorResponse/NoticeResponse
// into a PostgresServerError. The protocol guarantees a severity, a SQLSTATE
// code ('C'), and a primary message ('M') on every such message; their absence
// means a corrupt stream, so this throws a protocol error rather than inventing
// a placeholder. Severity prefers the non-localized 'V' field (PostgreSQL 9.6+)
// and falls back to the localized 'S' field.
enum ServerErrorAssembler {

    private static let severityNonLocalized: UInt8 = 0x56
    private static let severityLocalized: UInt8 = 0x53
    private static let sqlStateCode: UInt8 = 0x43
    private static let messageCode: UInt8 = 0x4d

    static func assemble(from pairs: [(code: UInt8, value: String)]) throws(PostgresError) -> PostgresServerError {
        let severity = try resolveSeverity(pairs)
        let sqlState = try require(pairs, code: sqlStateCode, label: "SQLSTATE code")
        let message = try require(pairs, code: messageCode, label: "primary message")
        return PostgresServerError(severity: severity, sqlState: sqlState, message: message, fields: extras(from: pairs))
    }

    private static func resolveSeverity(_ pairs: [(code: UInt8, value: String)]) throws(PostgresError) -> String {
        for pair in pairs where pair.code == severityNonLocalized {
            return pair.value
        }
        return try require(pairs, code: severityLocalized, label: "severity")
    }

    private static func require(_ pairs: [(code: UInt8, value: String)], code: UInt8, label: String) throws(PostgresError) -> String {
        for pair in pairs where pair.code == code {
            return pair.value
        }
        throw PostgresError.protocolError(reason: "server error message missing required \(label) field")
    }

    private static func extras(from pairs: [(code: UInt8, value: String)]) -> [PostgresServerError.Field] {
        var fields: [PostgresServerError.Field] = []
        for pair in pairs where !isGuaranteedField(pair.code) {
            fields.append(PostgresServerError.Field(code: pair.code, value: pair.value))
        }
        return fields
    }

    private static func isGuaranteedField(_ code: UInt8) -> Bool {
        switch code {
        case severityNonLocalized, severityLocalized, sqlStateCode, messageCode: true
        default: false
        }
    }
}
