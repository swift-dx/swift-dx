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

/// The query-running capability of a PostgreSQL client. A type that only needs
/// to run statements — most application code — can depend on `some PostgresQuerying`
/// rather than the full ``PostgresClient``, which narrows the surface a test
/// double must implement. A statement with no bound parameters runs over the
/// simple query protocol; one with parameters runs over the extended protocol.
public protocol PostgresQuerying: Sendable {

    func query(_ sql: String) async throws(PostgresError) -> PostgresQueryResult
    func query(_ sql: String, binding parameters: [any PostgresEncodable]) async throws(PostgresError) -> PostgresQueryResult
    func query(_ query: PostgresQuery) async throws(PostgresError) -> PostgresQueryResult
}
