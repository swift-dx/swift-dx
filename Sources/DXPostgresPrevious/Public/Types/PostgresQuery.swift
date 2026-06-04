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

/// A statement and its already-encoded bound parameters. The parameters are
/// referenced positionally in the SQL as `$1`, `$2`, and so on, and are each a
/// ``PostgresCell`` in text format (or ``PostgresCell/sqlNull``). A query with no
/// parameters runs over the simple query protocol; a query with parameters runs
/// over the extended protocol with a parse/bind/execute exchange.
public struct PostgresQuery: Sendable {

    public let sql: String
    public let parameters: [PostgresCell]

    public init(_ sql: String) {
        self.sql = sql
        self.parameters = []
    }

    public init(_ sql: String, parameters: [PostgresCell]) {
        self.sql = sql
        self.parameters = parameters
    }
}
