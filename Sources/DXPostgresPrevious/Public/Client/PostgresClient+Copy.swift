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

extension PostgresClient {

    /// Bulk-loads rows into a table with `COPY … FROM STDIN`, the fastest way to
    /// ingest a large dataset: the rows stream to the server in one operation and
    /// commit once. Each element of `rows` is the values for one row in column
    /// order; pass ``PostgresNull`` for a SQL NULL. Returns the number of rows the
    /// server reports loaded.
    ///
    /// ```swift
    /// let loaded = try await postgres.copyIn(
    ///     into: "events",
    ///     columns: ["id", "name"],
    ///     rows: records.map { [$0.id, $0.name] }
    /// )
    /// ```
    public func copyIn<Rows: Sequence & Sendable>(into table: String, columns: [String], rows: Rows) async throws(PostgresError) -> Int where Rows.Element == [any PostgresEncodable] {
        let statement = Self.copyStatement(table: table, columns: columns)
        return try await PostgresError.bridge {
            try await self.pool.withConnection { connection in
                try await connection.performCopyIn(sql: statement, rows: rows)
            }
        }
    }

    private static func copyStatement(table: String, columns: [String]) -> String {
        "COPY \(table) (\(columns.joined(separator: ", "))) FROM STDIN"
    }
}
