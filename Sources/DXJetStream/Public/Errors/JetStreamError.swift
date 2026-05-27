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

public enum JetStreamError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidStreamName(String)
    case invalidConsumerName(String)
    case invalidSubject(String)
    case notConnected
    case connectionFailed(reason: String)
    case handshakeFailed(reason: String)
    case protocolError(reason: String)
    case serverError(reason: String)
    case publishAckError(reason: String)
    case publishTimedOut
    case fetchStatus(code: UInt16)
    case fetchClosedBeforeCompletion
    case credentialsEnvironmentMissing(variable: String)
    case credentialsBase64Invalid(reason: String)
    case credentialsJwtMissing
    case credentialsSeedMissing
    case credentialsSeedInvalid(reason: String)
    case credentialsSignatureFailed(reason: String)
    case credentialsNonceMissing
    case transportError(reason: String)

    public var description: String {
        switch self {
        case .invalidStreamName(let name): return "invalid stream name: \(name) (allowed: ASCII letters, digits, '-', '_', non-empty, max 255)"
        case .invalidConsumerName(let name): return "invalid consumer name: \(name) (allowed: ASCII letters, digits, '-', '_', non-empty, max 255)"
        case .invalidSubject(let subject): return "invalid subject: \(subject) (allowed: dot-separated tokens of [A-Za-z0-9_\\-$])"
        case .notConnected: return "operation requires an open connection; call JetStream.connect first"
        case .connectionFailed(let reason): return "connection failed: \(reason)"
        case .handshakeFailed(let reason): return "NATS handshake failed: \(reason)"
        case .protocolError(let reason): return "NATS protocol error: \(reason)"
        case .serverError(let reason): return "NATS server returned -ERR: \(reason)"
        case .publishAckError(let reason): return "JetStream PublishAck error: \(reason)"
        case .publishTimedOut: return "publish timed out waiting for +ACK"
        case .fetchStatus(let code): return "fetch returned non-OK status code \(code) (e.g. 404 no messages, 408 request expired)"
        case .fetchClosedBeforeCompletion: return "fetch stream was closed before the request completed"
        case .credentialsEnvironmentMissing(let variable): return "credentials environment variable not set: \(variable)"
        case .credentialsBase64Invalid(let reason): return "credentials base64 decode failed: \(reason)"
        case .credentialsJwtMissing: return "credentials file is missing the NATS USER JWT block"
        case .credentialsSeedMissing: return "credentials file is missing the USER NKEY SEED block"
        case .credentialsSeedInvalid(let reason): return "credentials NKey seed invalid: \(reason)"
        case .credentialsSignatureFailed(let reason): return "credentials signing failed: \(reason)"
        case .credentialsNonceMissing: return "broker requested signed handshake but did not send a nonce"
        case .transportError(let reason): return "transport error: \(reason)"
        }
    }
}
