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

    /// Leases one pooled connection for the duration of `body` and runs every query
    /// issued through the supplied ``PostgresSession`` on it. The pool is entered
    /// once when the lease starts and once when it ends, not on every statement, so
    /// a burst of queries on the session does not serialize behind the pool actor
    /// the way repeated ``query(_:)`` calls do. This is the high-throughput path for
    /// a task that runs many queries: a request handler, a batch loop, a cursor
    /// walk. The connection is returned to the pool when `body` returns or throws.
    ///
    /// Statements autocommit unless `body` issues its own `BEGIN`/`COMMIT`. The
    /// session does not transparently retry transient failures; for transparent
    /// retry of a single statement, use ``query(_:)`` directly.
    public func withConnection<Result: Sendable>(_ body: @Sendable (PostgresSession) async throws -> Result) async throws -> Result {
        try await pool.withConnection { connection in
            try await body(PostgresSession(connection: connection))
        }
    }
}
