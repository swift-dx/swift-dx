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

/// A connection leased to a caller for the duration of a ``PostgresLeasePool``
/// `withConnection` closure. Its methods are synchronous and run on the leased
/// connection's own dedicated thread, so a run of queries inside one lease costs
/// no per-query async hand-off — the lease pays one hand-off and then proceeds at
/// the speed of the synchronous core. The handle is valid only inside the closure
/// and must not be stored or shared; it is deliberately not `Sendable`.
public struct PostgresLeasedConnection {

    private let connection: BlockingPostgresConnection

    init(connection: BlockingPostgresConnection) {
        self.connection = connection
    }

    public func queryScalarInt64(_ sql: String, value: Int64) throws(PostgresError) -> Int64 {
        try connection.queryScalarInt64Inline(sql, value: value)
    }
}
