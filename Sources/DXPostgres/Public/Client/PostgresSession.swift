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

/// A handle to one pooled connection leased for the lifetime of a
/// ``PostgresClient/withConnection(_:)`` body. Every query issued through it runs
/// on that one connection without re-entering the pool, so a task that runs many
/// queries pays the pool's bookkeeping once at lease time instead of on every
/// statement. Use it for a burst of related queries — a request handler, a batch
/// loop, a cursor walk — where ``PostgresClient/query(_:)`` would otherwise lease
/// and return a connection per call and serialize every caller through the pool.
///
/// A session is not a transaction: statements autocommit unless the body issues
/// its own `BEGIN`/`COMMIT`. Unlike ``PostgresClient/query(_:)`` a session does not
/// transparently retry transient failures, because a retry would have to move to a
/// different connection and break the session's single-connection guarantee; a
/// caller that needs retry uses the client directly or re-leases. The handle is
/// valid only for the duration of the body.
public final class PostgresSession: Sendable {

    let connection: PostgresConnection

    init(connection: PostgresConnection) {
        self.connection = connection
    }
}

extension PostgresSession {

    /// Sends one SQL string with many parameter sets in a single network
    /// round-trip and returns one result per set, in order. Each set runs as its
    /// own autocommit statement, so a failure in one is isolated to that result's
    /// error while the rest still apply. This is the throughput path for a burst of
    /// the same write or read: the server receives the whole batch in one write and
    /// streams the results back, instead of the caller paying a round-trip per
    /// statement. The statement is parsed once and reused across the batch.
    public func pipeline(_ sql: String, bindings: [[any PostgresEncodable]]) async throws(PostgresError) -> [PostgresQueryResult] {
        var parameterSets: [[PostgresCell]] = []
        parameterSets.reserveCapacity(bindings.count)
        for binding in bindings {
            parameterSets.append(try PostgresParameterEncoding.cells(from: binding))
        }
        return try await connection.pipelineExtended(sql: sql, parameterSets: parameterSets)
    }
}

extension PostgresSession: PostgresQuerying {

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
