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

import Logging

/// How a ``SQLiteDatabase`` is opened and pooled.
///
/// A SQLite database serializes writes to a single connection regardless of how
/// many a process opens, so DXSQLite holds exactly one writer and a bounded pool
/// of reader connections. `maxReaders` sizes that read pool — the number of
/// reads that can run concurrently against the database. `busyTimeoutMilliseconds`
/// is how long a connection waits for a held lock before failing, which under
/// WAL chiefly affects the writer during checkpoints.
public struct SQLiteConfiguration: Sendable {

    public let location: SQLiteLocation
    public let maxReaders: Int
    public let busyTimeoutMilliseconds: Int
    public let tuning: SQLiteTuning
    public let authorization: SQLiteAuthorizationPolicy
    public let functions: [SQLiteFunction]
    public let aggregates: [SQLiteAggregate]
    public let collations: [SQLiteCollation]
    public let virtualTables: [any SQLiteTableProvider]
    public let logger: Logger

    public init(
        location: SQLiteLocation,
        maxReaders: Int = 4,
        busyTimeoutMilliseconds: Int = 5_000,
        tuning: SQLiteTuning = SQLiteTuning(),
        authorization: SQLiteAuthorizationPolicy = .unrestricted,
        functions: [SQLiteFunction] = [],
        aggregates: [SQLiteAggregate] = [],
        collations: [SQLiteCollation] = [],
        virtualTables: [any SQLiteTableProvider] = [],
        logger: Logger = Logger(label: "swift.dx.sqlite")
    ) {
        self.location = location
        self.maxReaders = maxReaders
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.tuning = tuning
        self.authorization = authorization
        self.functions = functions
        self.aggregates = aggregates
        self.collations = collations
        self.virtualTables = virtualTables
        self.logger = logger
    }

    var customizations: SQLiteConnectionCustomizations {
        .init(tuning: tuning, authorization: authorization, functions: functions, aggregates: aggregates, collations: collations, virtualTables: virtualTables)
    }
}
