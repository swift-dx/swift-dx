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
        case .connectionClosed, .connectFailed, .transportError, .poolExhausted, .allConnectionsDown:
            true
        case .server(let serverError):
            serverError.isRetryable
        case .handshakeFailed, .authenticationFailed, .unsupportedAuthentication, .tlsNotSupportedByServer, .timedOut, .protocolError, .poolShutdown, .poolHasNoEndpoints, .columnIndexOutOfRange, .columnNameNotFound, .columnIsNull, .typeDecodingFailed, .parameterCountMismatch, .jsonEncodingFailed, .jsonDecodingFailed, .utf8DecodingFailed, .cancelled, .noCurrentClient:
            false
        }
    }

    // Whether the failure means the connection itself is broken and must be torn
    // down and rebuilt rather than returned to the pool: a send or receive failed,
    // or the peer closed the socket. A server error or a caller mistake leaves the
    // connection usable, so those return false and the connection is reused.
    var isConnectionFatal: Bool {
        switch self {
        case .connectionClosed, .transportError:
            true
        case .connectFailed, .handshakeFailed, .authenticationFailed, .unsupportedAuthentication, .tlsNotSupportedByServer, .timedOut, .protocolError, .server, .poolExhausted, .allConnectionsDown, .poolShutdown, .poolHasNoEndpoints, .columnIndexOutOfRange, .columnNameNotFound, .columnIsNull, .typeDecodingFailed, .parameterCountMismatch, .jsonEncodingFailed, .jsonDecodingFailed, .utf8DecodingFailed, .cancelled, .noCurrentClient:
            false
        }
    }

    // Whether the failure can fire after a statement has already reached the
    // server, leaving its outcome unknown: the connection may have dropped between
    // the server committing the write and the acknowledgement reaching the client.
    // Retrying such a failure could double-apply a non-idempotent statement, so it
    // is retried only for read-only statements that carry no persistent effect.
    // Connection-acquisition failures (connectFailed, poolExhausted) and server
    // errors that rolled the statement back are NOT ambiguous — nothing was
    // applied — so they stay safe to retry for any statement.
    var isAmbiguous: Bool {
        switch self {
        case .connectionClosed, .transportError, .timedOut:
            true
        case .connectFailed, .poolExhausted, .allConnectionsDown, .server, .handshakeFailed, .authenticationFailed, .unsupportedAuthentication, .tlsNotSupportedByServer, .protocolError, .poolShutdown, .poolHasNoEndpoints, .columnIndexOutOfRange, .columnNameNotFound, .columnIsNull, .typeDecodingFailed, .parameterCountMismatch, .jsonEncodingFailed, .jsonDecodingFailed, .utf8DecodingFailed, .cancelled, .noCurrentClient:
            false
        }
    }
}
