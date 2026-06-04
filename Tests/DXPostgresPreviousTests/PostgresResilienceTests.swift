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

@Suite struct PostgresResilienceTests {

    @Test func connectionLayerFailuresAreTransient() {
        #expect(PostgresError.connectionClosed.isTransient)
        #expect(PostgresError.connectFailed(reason: "refused").isTransient)
        #expect(PostgresError.transportError(reason: "reset").isTransient)
        #expect(PostgresError.poolExhausted(maxConnections: 4).isTransient)
    }

    @Test func serializationFailuresAndDeadlocksAreTransient() {
        #expect(PostgresError.server(PostgresServerError(severity: "ERROR", sqlState: "40001", message: "restart read required")).isTransient)
        #expect(PostgresError.server(PostgresServerError(severity: "ERROR", sqlState: "40P01", message: "deadlock detected")).isTransient)
    }

    @Test func serverAndCallerErrorsAreNotTransient() {
        let serverError = PostgresServerError(severity: "ERROR", sqlState: "23505", message: "duplicate key", fields: [])
        #expect(!PostgresError.server(serverError).isTransient)
        #expect(!PostgresError.timedOut.isTransient)
        #expect(!PostgresError.protocolError(reason: "bad frame").isTransient)
        #expect(!PostgresError.poolShutdown.isTransient)
        #expect(!PostgresError.typeDecodingFailed(type: "Int", reason: "x").isTransient)
    }

    @Test func disabledTurnsOffRetry() {
        #expect(PostgresResilience.disabled.retryTransientFailures == false)
        #expect(PostgresResilience().retryTransientFailures == true)
    }
}
