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

/// A read-write handle to the database, valid only for the duration of the
/// ``SQLiteDatabase/write(_:)`` closure it is passed to.
///
/// Every writer closure runs on the one writer connection, serialized on its
/// own thread, so a write never races another write. Do not let the writer
/// escape the closure.
public struct SQLiteWriter: Sendable {

    let connection: SQLiteConnection

    public func execute(_ sql: String) throws(SQLiteError) {
        try connection.execute(sql)
    }

    public func query(_ sql: String, parameters: [SQLiteValue] = []) throws(SQLiteError) -> [SQLiteRow] {
        try connection.query(sql, parameters)
    }

    public func mutate(_ sql: String, parameters: [SQLiteValue] = []) throws(SQLiteError) -> Int {
        let statement = try connection.prepare(sql)
        try statement.bindAll(parameters)
        _ = try statement.step()
        return connection.changedRowCount
    }

    public func transaction<Value>(_ body: (SQLiteWriter) throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body(self)
            try execute("COMMIT;")
            return value
        } catch {
            try execute("ROLLBACK;")
            throw error
        }
    }

    public var lastInsertRowID: Int64 {
        connection.lastInsertRowID
    }

    public func backup(toFile path: String) throws(SQLiteError) {
        try connection.backup(toFile: path)
    }

    public func serialize() throws(SQLiteError) -> [UInt8] {
        try connection.serialize()
    }

    public func withBlob<Value>(table: String, column: String, rowID: Int64, _ body: (SQLiteBlob) throws -> Value) throws -> Value {
        try connection.withBlob(table: table, column: column, rowID: rowID, readOnly: false, body)
    }

    public func recordingChangeset(_ body: (SQLiteWriter) throws -> Void) throws -> [UInt8] {
        try connection.recordingChangeset { try body(self) }
    }

    public func applyChangeset(_ changeset: [UInt8]) throws(SQLiteError) {
        try connection.applyChangeset(changeset)
    }
}

extension SQLiteWriter {

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
