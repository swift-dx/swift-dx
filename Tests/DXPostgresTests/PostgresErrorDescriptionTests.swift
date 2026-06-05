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
import DXPostgres

@Suite struct PostgresErrorDescriptionTests {

    private let serverError = PostgresServerError(severity: "ERROR", sqlState: "22012", message: "division by zero")

    private var everyCase: [PostgresError] {
        [
            .connectionClosed,
            .connectFailed(reason: "connection refused"),
            .handshakeFailed(reason: "bad startup"),
            .authenticationFailed(reason: "wrong password"),
            .unsupportedAuthentication(method: "GSS"),
            .tlsNotSupportedByServer,
            .transportError(reason: "broken pipe"),
            .timedOut,
            .protocolError(reason: "unexpected tag"),
            .server(serverError),
            .poolExhausted(maxConnections: 8),
            .poolShutdown,
            .poolHasNoEndpoints,
            .columnIndexOutOfRange(index: 5, columnCount: 2),
            .columnNameNotFound(name: "email"),
            .columnIsNull(column: "note"),
            .typeDecodingFailed(type: "Account", reason: "not an int"),
            .parameterCountMismatch(expected: 1, provided: 2),
            .jsonEncodingFailed(typeName: "Order", reason: "cycle"),
            .jsonDecodingFailed(typeName: "Order", reason: "truncated"),
            .utf8DecodingFailed,
            .cancelled,
            .noCurrentClient,
        ]
    }

    @Test func everyCaseProducesANonEmptyDescription() {
        for error in everyCase {
            #expect(error.description.isEmpty == false)
            requireExhaustive(error)
        }
    }

    @Test func descriptionsCarryTheirAssociatedDetail() {
        #expect(PostgresError.server(serverError).description.contains("22012"))
        #expect(PostgresError.server(serverError).description.contains("division by zero"))
        #expect(PostgresError.columnIndexOutOfRange(index: 5, columnCount: 2).description.contains("5"))
        #expect(PostgresError.parameterCountMismatch(expected: 1, provided: 2).description.contains("2"))
        #expect(PostgresError.connectFailed(reason: "connection refused").description.contains("connection refused"))
    }

    // Exhaustive, default-free switch: a newly added error case stops this file
    // from compiling, forcing a deliberate decision about the new case.
    private func requireExhaustive(_ error: PostgresError) {
        switch error {
        case .connectionClosed, .connectFailed, .handshakeFailed, .authenticationFailed,
             .unsupportedAuthentication, .tlsNotSupportedByServer, .transportError, .timedOut,
             .protocolError, .server, .poolExhausted, .poolShutdown, .poolHasNoEndpoints,
             .columnIndexOutOfRange, .columnNameNotFound, .columnIsNull, .typeDecodingFailed,
             .parameterCountMismatch, .jsonEncodingFailed, .jsonDecodingFailed, .utf8DecodingFailed,
             .cancelled, .noCurrentClient:
            break
        }
    }
}
