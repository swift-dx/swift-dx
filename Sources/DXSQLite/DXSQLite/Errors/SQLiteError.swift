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

/// The single typed error surface of DXSQLite.
///
/// Every throwing operation in the library throws this type. Cases carry the
/// SQLite result code and the engine's own message where one is available, so
/// an operator reading a log line sees both the numeric code and its meaning
/// without consulting the call site.
public enum SQLiteError: Error, Sendable, Equatable {

    case cannotOpenDatabase(path: String, code: Int32, message: String)
    case executeFailed(sql: String, code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(parameterIndex: Int32, code: Int32, message: String)
    case functionRegistrationFailed(name: String, code: Int32, message: String)
    case virtualTableRegistrationFailed(name: String, code: Int32, message: String)
    case backupFailed(code: Int32, message: String)
    case serializationFailed(message: String)
    case blobFailed(operation: String, code: Int32, message: String)
    case sessionFailed(operation: String, code: Int32, message: String)
    case unexpectedColumnType(columnIndex: Int32, rawType: Int32)
    case columnNotFound(name: String)
    case valueTypeMismatch(expected: ColumnType, actual: ColumnType)
    case decodingFailed(type: String, reason: String)
    case encodingFailed(type: String, reason: String)
    case poolExhausted(maxReaders: Int)
    case databaseClosed
    case noCurrentDatabase
}

extension SQLiteError: CustomStringConvertible {

    public var description: String {
        switch self {
        case .cannotOpenDatabase(let path, let code, let message): "cannot open database at \(path): \(message) (code \(code))"
        case .executeFailed(let sql, let code, let message): "failed to execute \(sql): \(message) (code \(code))"
        case .prepareFailed(let sql, let code, let message): "failed to prepare \(sql): \(message) (code \(code))"
        case .stepFailed(let code, let message): "failed to step statement: \(message) (code \(code))"
        case .bindFailed(let parameterIndex, let code, let message): "failed to bind parameter \(parameterIndex): \(message) (code \(code))"
        case .functionRegistrationFailed(let name, let code, let message): "failed to register SQL function \(name): \(message) (code \(code))"
        case .virtualTableRegistrationFailed(let name, let code, let message): "failed to register virtual table \(name): \(message) (code \(code))"
        case .backupFailed(let code, let message): "database backup failed: \(message) (code \(code))"
        case .serializationFailed(let message): "database serialization failed: \(message)"
        case .blobFailed(let operation, let code, let message): "blob \(operation) failed: \(message) (code \(code))"
        case .sessionFailed(let operation, let code, let message): "session \(operation) failed: \(message) (code \(code))"
        case .unexpectedColumnType(let columnIndex, let rawType): "column \(columnIndex) reported unknown SQLite type code \(rawType)"
        case .columnNotFound(let name): "no column named \(name) in the result row"
        case .valueTypeMismatch(let expected, let actual): "expected \(expected) but found \(actual)"
        case .decodingFailed(let type, let reason): "failed to decode \(type) from the row: \(reason)"
        case .encodingFailed(let type, let reason): "failed to encode \(type) to JSON: \(reason)"
        case .poolExhausted(let maxReaders): "reader pool exhausted at \(maxReaders) connections"
        case .databaseClosed: "the database has been closed"
        case .noCurrentDatabase: "no database is bound to the current task; bind one with SQLite.withCurrent(_:_:) before calling SQLite.current()"
        }
    }
}
