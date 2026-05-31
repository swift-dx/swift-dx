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

/// One result row: the column values in declaration order alongside their names.
///
/// Values are read out of SQLite eagerly into ``SQLiteValue`` cases, so a row
/// outlives the statement that produced it and is safe to return from a read.
/// Look a column up positionally through ``columns`` or by name with
/// ``value(named:)``, which throws rather than returning a sentinel when the
/// name is absent.
public struct SQLiteRow: Sendable, Equatable {

    public let columns: [SQLiteValue]
    public let columnNames: [String]

    public init(columns: [SQLiteValue], columnNames: [String]) {
        self.columns = columns
        self.columnNames = columnNames
    }

    public func value(named name: String) throws(SQLiteError) -> SQLiteValue {
        guard let index = columnNames.firstIndex(of: name) else {
            throw SQLiteError.columnNotFound(name: name)
        }
        return columns[index]
    }

    public func integer(named name: String) throws(SQLiteError) -> Int64 {
        try value(named: name).integer()
    }

    public func double(named name: String) throws(SQLiteError) -> Double {
        try value(named: name).double()
    }

    public func text(named name: String) throws(SQLiteError) -> String {
        try value(named: name).text()
    }

    public func blob(named name: String) throws(SQLiteError) -> [UInt8] {
        try value(named: name).blob()
    }

    public func boolean(named name: String) throws(SQLiteError) -> Bool {
        try value(named: name).boolean()
    }
}

extension SQLiteRow {

    public func decode<T: Decodable>(_ type: T.Type) throws(SQLiteError) -> T {
        let decoder = SQLiteRowDecoder(row: self)
        do {
            return try T(from: decoder)
        } catch let error as SQLiteError {
            throw error
        } catch {
            throw SQLiteError.decodingFailed(type: String(describing: T.self), reason: String(describing: error))
        }
    }
}
