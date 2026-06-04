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

extension PostgresClient: PostgresQuerying {

    public func query(_ sql: String) async throws(PostgresError) -> PostgresQueryResult {
        try await withConnection(statement: sql) { connection in
            try await connection.simpleQuery(sql)
        }
    }

    public func query(_ sql: String, binding parameters: [any PostgresEncodable]) async throws(PostgresError) -> PostgresQueryResult {
        let cells = try encodeParameters(parameters)
        return try await withConnection(statement: sql) { connection in
            try await connection.extendedQuery(sql, parameters: cells)
        }
    }

    public func query(_ query: PostgresQuery) async throws(PostgresError) -> PostgresQueryResult {
        let parameters = query.parameters
        let sql = query.sql
        guard !parameters.isEmpty else {
            return try await self.query(sql)
        }
        return try await withConnection(statement: sql) { connection in
            try await connection.extendedQuery(sql, parameters: parameters)
        }
    }

    func encodeParameters(_ parameters: [any PostgresEncodable]) throws(PostgresError) -> [PostgresCell] {
        try PostgresParameterEncoding.cells(from: parameters)
    }

    private func withConnection<Value: Sendable>(statement: String, _ body: @Sendable @escaping (PostgresConnection) async throws -> Value) async throws(PostgresError) -> Value {
        try await withResilience(statement: statement) {
            try await self.pool.withConnection(body)
        }
    }
}
