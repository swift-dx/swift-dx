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

/// A handle to an in-progress transaction, scoped to one pooled connection for
/// the lifetime of a ``PostgresClient/withTransaction(_:)`` body. Every query run
/// through it executes on the same connection inside the same transaction, so a
/// batch of writes commits once instead of one fsync per statement, and either
/// all of them apply or none do. Issue queries through this handle, not the
/// originating client, inside the body; the client would acquire a different
/// connection outside the transaction. The handle is valid only for the duration
/// of the body.
public final class PostgresTransaction: Sendable {

    let connection: PostgresConnection

    init(connection: PostgresConnection) {
        self.connection = connection
    }
}

extension PostgresTransaction: PostgresQuerying {

    public func query(_ sql: String) async throws(PostgresError) -> PostgresQueryResult {
        try await connection.simpleQuery(sql)
    }

    public func query(_ sql: String, binding parameters: [any PostgresEncodable]) async throws(PostgresError) -> PostgresQueryResult {
        try await connection.extendedQuery(sql, parameters: PostgresParameterEncoding.cells(from: parameters))
    }

    public func query(_ query: PostgresQuery) async throws(PostgresError) -> PostgresQueryResult {
        guard !query.parameters.isEmpty else {
            return try await connection.simpleQuery(query.sql)
        }
        return try await connection.extendedQuery(query.sql, parameters: query.parameters)
    }
}
