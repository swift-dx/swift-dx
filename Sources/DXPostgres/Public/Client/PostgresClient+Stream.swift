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

    /// Streams a result set row by row instead of buffering it whole, so a large
    /// scan never materializes every row in memory at once. The stream owns a
    /// pooled connection for its lifetime and returns it when iteration finishes;
    /// abandoning the stream early (a `break` out of the loop) closes that
    /// connection rather than reusing a half-read one. Iteration throws
    /// ``PostgresError`` values, surfaced as `any Error` because the standard
    /// library's `AsyncThrowingStream` does not yet carry a typed failure.
    ///
    /// ```swift
    /// for try await row in postgres.queryStream("SELECT id FROM large_table") {
    ///     try handle(row.decode(Int.self, named: "id"))
    /// }
    /// ```
    public func queryStream(_ sql: String) -> AsyncThrowingStream<PostgresRow, Error> {
        rowStream { connection in
            connection.beginSimpleQuery(sql)
        }
    }

    public func queryStream(_ sql: String, binding parameters: [any PostgresEncodable]) -> AsyncThrowingStream<PostgresRow, Error> {
        rowStream { connection in
            connection.beginExtendedQuery(sql: sql, parameters: try self.encodeParameters(parameters))
        }
    }

    private func rowStream(_ write: @escaping @Sendable (PostgresConnection) throws -> Void) -> AsyncThrowingStream<PostgresRow, Error> {
        AsyncThrowingStream { continuation in
            let driver = PostgresRowStreamDriver(pool: pool, continuation: continuation, write: write)
            continuation.onTermination = { _ in driver.terminate() }
            driver.start()
        }
    }
}
