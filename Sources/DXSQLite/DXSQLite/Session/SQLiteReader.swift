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

/// A read-only handle to the database, valid only for the duration of the
/// ``SQLiteDatabase/read(_:)`` closure it is passed to.
///
/// It runs on a connection opened `SQLITE_OPEN_READONLY`, so any attempt to
/// write fails at the engine. Do not let the reader escape the closure; the
/// connection is returned to the pool the moment the closure returns.
public struct SQLiteReader: Sendable {

    let connection: SQLiteConnection

    public func query(_ sql: String, parameters: [SQLiteValue] = []) throws(SQLiteError) -> [SQLiteRow] {
        try connection.query(sql, parameters)
    }

    public func backup(toFile path: String) throws(SQLiteError) {
        try connection.backup(toFile: path)
    }

    public func serialize() throws(SQLiteError) -> [UInt8] {
        try connection.serialize()
    }

    public func withBlob<Value>(table: String, column: String, rowID: Int64, _ body: (SQLiteBlob) throws -> Value) throws -> Value {
        try connection.withBlob(table: table, column: column, rowID: rowID, readOnly: true, body)
    }
}

extension SQLiteReader {

    public func query<T: Decodable>(_ sql: String, parameters: [SQLiteValue] = [], as type: T.Type) throws(SQLiteError) -> [T] {
        let rows = try query(sql, parameters: parameters)
        var decoded: [T] = []
        decoded.reserveCapacity(rows.count)
        for row in rows {
            decoded.append(try row.decode(T.self))
        }
        return decoded
    }
}
