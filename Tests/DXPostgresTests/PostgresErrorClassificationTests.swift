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

@Suite struct PostgresErrorClassificationTests {

    private struct SampleError: Error {}

    private var retryable: PostgresServerError { PostgresServerError(severity: "ERROR", sqlState: "40001", message: "serialization failure") }
    private var nonRetryable: PostgresServerError { PostgresServerError(severity: "ERROR", sqlState: "22012", message: "division by zero") }

    @Test func translateNarrowsToTypedErrors() {
        #expect(PostgresError.translate(CancellationError()) == .cancelled)
        #expect(PostgresError.translate(PostgresError.poolShutdown) == .poolShutdown)
        guard case .transportError = PostgresError.translate(SampleError()) else {
            Issue.record("expected an unknown error to map to transportError")
            return
        }
    }

    @Test func bridgeMapsCancellationToCancelled() async {
        do {
            _ = try await PostgresError.bridge { throw CancellationError() }
            Issue.record("expected the bridge to surface cancellation as cancelled")
        } catch {
            #expect(error == .cancelled)
        }
    }

    @Test func bridgePassesTypedErrorsThroughAndReturnsValues() async throws {
        let value = try await PostgresError.bridge { 42 }
        #expect(value == 42)
        do {
            _ = try await PostgresError.bridge { throw PostgresError.poolShutdown }
            Issue.record("expected the typed error to pass through")
        } catch {
            #expect(error == .poolShutdown)
        }
    }

    @Test func transientClassificationGuardsRetrySafety() {
        #expect(PostgresError.connectionClosed.isTransient)
        #expect(PostgresError.connectFailed(reason: "x").isTransient)
        #expect(PostgresError.transportError(reason: "x").isTransient)
        #expect(PostgresError.poolExhausted(maxConnections: 1).isTransient)
        #expect(PostgresError.server(retryable).isTransient)
        #expect(PostgresError.server(nonRetryable).isTransient == false)
        #expect(PostgresError.cancelled.isTransient == false)
        #expect(PostgresError.timedOut.isTransient == false)
        #expect(PostgresError.typeDecodingFailed(type: "X", reason: "y").isTransient == false)
    }

    @Test func ambiguousClassificationGuardsNonIdempotentReplay() {
        #expect(PostgresError.connectionClosed.isAmbiguous)
        #expect(PostgresError.transportError(reason: "x").isAmbiguous)
        #expect(PostgresError.timedOut.isAmbiguous)
        #expect(PostgresError.connectFailed(reason: "x").isAmbiguous == false)
        #expect(PostgresError.poolExhausted(maxConnections: 1).isAmbiguous == false)
        #expect(PostgresError.server(retryable).isAmbiguous == false)
    }
}
