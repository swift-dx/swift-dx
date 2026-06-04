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

import Testing

@testable import DXPostgresPrevious

// Classifies which server errors mean a reused prepared statement should be
// re-parsed: PostgreSQL's "cached plan must not change result type" (0A000) and
// "prepared statement does not exist" (26000), plus YugabyteDB's internal
// object-not-found (XX000) after a table is replaced.
@Suite struct StalePreparedStatementTests {

    private func error(_ sqlState: String, _ message: String = "boom") -> PostgresServerError {
        PostgresServerError(severity: "ERROR", sqlState: sqlState, message: message)
    }

    @Test func recognizesCachedPlanAndMissingStatement() {
        #expect(PostgresConnection.indicatesStalePreparedStatement(error("0A000", "cached plan must not change result type")))
        #expect(PostgresConnection.indicatesStalePreparedStatement(error("26000", "prepared statement \"s1\" does not exist")))
    }

    @Test func recognizesYugabyteObjectNotFound() {
        #expect(PostgresConnection.indicatesStalePreparedStatement(error("XX000", "The object 'abc.tbl' does not exist: OBJECT_NOT_FOUND")))
    }

    @Test func leavesRealErrorsAlone() {
        #expect(!PostgresConnection.indicatesStalePreparedStatement(error("23505", "duplicate key")))
        #expect(!PostgresConnection.indicatesStalePreparedStatement(error("42P01", "relation does not exist")))
        #expect(!PostgresConnection.indicatesStalePreparedStatement(error("XX000", "some unrelated internal error")))
    }
}
