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

/// The rawest decoded form of a query result: the column descriptions sent once
/// by the server (each carrying a name, a type object identifier, and a wire
/// format), paired with the rows. Each row is a positional array of fields whose
/// index matches `columns`; a field is either its raw wire bytes or SQL NULL. The
/// server does not repeat the column metadata per row, so reconstructing a named,
/// typed value means pairing `rows[r][c]` with `columns[c]`.
public struct PostgresResult: Sendable, Equatable {

    public let columns: [PostgresColumn]
    public let rows: [[PostgresCell]]

    public init(columns: [PostgresColumn], rows: [[PostgresCell]]) {
        self.columns = columns
        self.rows = rows
    }

    public func columnIndex(named name: String) throws(PostgresError) -> Int {
        for index in columns.indices where columns[index].name == name { return index }
        throw PostgresError.columnNameNotFound(name: name)
    }

    /// Decodes every row into `type` by matching each property's coding key to a
    /// column name. Throws ``PostgresError/typeDecodingFailed(type:reason:)`` if a
    /// value does not fit the property's type.
    public func decode<T: Decodable>(as type: T.Type) throws(PostgresError) -> [T] {
        let columnIndex = columnIndexByName()
        do {
            return try decodeRows(as: type, columnIndex: columnIndex)
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.typeDecodingFailed(type: "\(T.self)", reason: "\(error)")
        }
    }

    private func columnIndexByName() -> [String: Int] {
        var columnIndex: [String: Int] = [:]
        for index in columns.indices {
            columnIndex[columns[index].name] = index
        }
        return columnIndex
    }

    private func decodeRows<T: Decodable>(as type: T.Type, columnIndex: [String: Int]) throws -> [T] {
        var decoded: [T] = []
        decoded.reserveCapacity(rows.count)
        for row in rows {
            decoded.append(try T(from: PostgresRowDecoder(row: row, columnIndex: columnIndex)))
        }
        return decoded
    }
}
