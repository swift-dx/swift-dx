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
@testable import DXPostgres

@Suite struct PostgresTelemetryTests {

    @Test func instrumentedExecuteSurfacesTheUnderlyingError() async throws {
        await #expect(throws: PostgresError.noCurrentClient) {
            _ = try await Postgres.execute("SELECT 1")
        }
    }

    @Test func instrumentedQuerySurfacesTheUnderlyingError() async throws {
        await #expect(throws: PostgresError.noCurrentClient) {
            _ = try await Postgres.query("SELECT \(1)")
        }
    }

    @Test func instrumentedTransactionPreservesTheCallersOwnError() async throws {
        await #expect(throws: PostgresError.noCurrentClient) {
            try await Postgres.transaction { _ in }
        }
    }

    @Test func traceRecordsAResultAndPassesItThrough() async throws {
        let value = try await PostgresInstrumentation.trace("test") { 42 }
        #expect(value == 42)
    }

    @Test func traceRethrowingPreservesANonPostgresError() async throws {
        await #expect(throws: SampleFailure.boom) {
            try await PostgresInstrumentation.traceRethrowing("test") { throw SampleFailure.boom }
        }
    }

    private enum SampleFailure: Error {

        case boom
    }
}
