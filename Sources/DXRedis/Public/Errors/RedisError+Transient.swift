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

extension RedisError {

    // Whether retrying the operation on a fresh connection could resolve it. True
    // for connection-layer failures a reconnect or a freed pooled connection
    // fixes; false for server errors, malformed responses, and caller mistakes,
    // which retrying would only repeat.
    //
    // timedOut is deliberately NOT transient: a timeout fires after the command's
    // bytes are already on the wire, so its outcome is unknown. Retrying could
    // apply a non-idempotent command (INCR, LPUSH) twice. A timeout ends the
    // operation and the caller decides whether to reissue.
    var isTransient: Bool {
        switch self {
        case .connectionClosed, .transportError, .incompleteResponse, .poolExhausted:
            true
        case .timedOut, .handshakeFailed, .authenticationFailed, .protocolError, .responseDepthLimitExceeded, .malformedLength, .unexpectedResponseType, .serverError, .invalidDatabaseIndex, .emptyCommand, .emptyCommandBatch, .poolShutdown, .poolHasNoEndpoints, .jsonEncodingFailed, .jsonDecodingFailed, .integerConversionFailed, .utf8DecodingFailed, .lockNotAcquired, .cancelled, .noCurrentClient:
            false
        }
    }
}
