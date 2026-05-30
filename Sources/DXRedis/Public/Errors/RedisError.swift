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

public enum RedisError: Error, Sendable, Equatable, CustomStringConvertible {

    case connectionClosed
    case handshakeFailed(reason: String)
    case authenticationFailed(reason: String)
    case transportError(reason: String)
    case timedOut
    case protocolError(reason: String)
    case incompleteResponse
    case responseDepthLimitExceeded(limit: Int)
    case malformedLength(reason: String)
    case unexpectedResponseType(expected: String, actual: String)
    case serverError(prefix: String, message: String)
    case invalidDatabaseIndex(Int)
    case emptyCommand
    case emptyCommandBatch
    case poolExhausted(maxConnections: Int)
    case poolShutdown
    case poolHasNoEndpoints
    case jsonEncodingFailed(typeName: String, reason: String)
    case jsonDecodingFailed(typeName: String, reason: String)
    case integerConversionFailed(text: String)
    case utf8DecodingFailed
    case lockNotAcquired
    case cancelled
    case noCurrentClient

    public var description: String {
        switch self {
        case .connectionClosed: "the connection was closed before the command completed"
        case .handshakeFailed(let reason): "Redis handshake failed: \(reason)"
        case .authenticationFailed(let reason): "Redis authentication failed: \(reason)"
        case .transportError(let reason): "transport error: \(reason)"
        case .timedOut: "the command timed out before a response arrived"
        case .protocolError(let reason): "RESP protocol error: \(reason)"
        case .incompleteResponse: "the connection closed mid-response with a partial RESP frame"
        case .responseDepthLimitExceeded(let limit): "RESP array nesting exceeded the depth limit of \(limit)"
        case .malformedLength(let reason): "RESP length prefix malformed: \(reason)"
        case .unexpectedResponseType(let expected, let actual): "expected RESP \(expected) reply but received \(actual)"
        case .serverError(let prefix, let message): "Redis returned error \(prefix): \(message)"
        case .invalidDatabaseIndex(let value): "invalid database index \(value) (must be a non-negative integer)"
        case .emptyCommand: "a Redis command must contain at least the command name argument"
        case .emptyCommandBatch: "a pipeline must contain at least one command"
        case .poolExhausted(let maxConnections): "connection pool exhausted at \(maxConnections) connections"
        case .poolShutdown: "the connection pool has been shut down"
        case .poolHasNoEndpoints: "the connection pool was configured with no endpoints"
        case .jsonEncodingFailed(let typeName, let reason): "JSON encoding of \(typeName) failed: \(reason)"
        case .jsonDecodingFailed(let typeName, let reason): "JSON decoding of \(typeName) failed: \(reason)"
        case .integerConversionFailed(let text): "could not parse \(text) as a 64-bit signed integer"
        case .utf8DecodingFailed: "the reply payload was not valid UTF-8"
        case .lockNotAcquired: "the lock is held by another holder and could not be acquired"
        case .cancelled: "the command was cancelled"
        case .noCurrentClient: "no Redis client is bound to the current task; bind one with Redis.withCurrent(_:_:) before calling Redis.current()"
        }
    }
}
