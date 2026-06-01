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

extension PostgresError {

    // Whether retrying the operation on a freshly acquired connection could
    // resolve it: true for connection-layer failures a reconnect or a freed pool
    // slot fixes, false for server errors, decoding failures, and caller mistakes,
    // which a retry would only repeat. `timedOut` is deliberately not transient —
    // a timeout fires after the query is already on the wire, so its outcome is
    // unknown and a retry could double-apply a non-idempotent statement. The
    // switch is exhaustive with no default so a new error case forces a decision
    // here rather than silently defaulting to non-transient.
    var isTransient: Bool {
        switch self {
        case .connectionClosed, .connectFailed, .transportError, .poolExhausted:
            true
        case .server(let serverError):
            serverError.isRetryable
        case .handshakeFailed, .authenticationFailed, .unsupportedAuthentication, .tlsNotSupportedByServer, .timedOut, .protocolError, .poolShutdown, .poolHasNoEndpoints, .columnIndexOutOfRange, .columnNameNotFound, .columnIsNull, .typeDecodingFailed, .parameterCountMismatch, .jsonEncodingFailed, .jsonDecodingFailed, .utf8DecodingFailed, .cancelled, .noCurrentClient:
            false
        }
    }
}
