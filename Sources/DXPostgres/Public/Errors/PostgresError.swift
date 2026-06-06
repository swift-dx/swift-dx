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

/// The single typed error surface of DXPostgres. Every public throwing function
/// throws this type, so a caller can switch over the failure exhaustively. A
/// failure reported by the server itself arrives as ``server(_:)`` carrying the
/// structured ``PostgresServerError`` (severity, SQLSTATE, message, and fields);
/// failures detected on the client side — transport, protocol framing, decoding,
/// pool state — have their own cases with the context needed to act on them.
public enum PostgresError: Error, Sendable, Equatable {

    case connectionClosed
    case connectFailed(reason: String)
    case handshakeFailed(reason: String)
    case authenticationFailed(reason: String)
    case unsupportedAuthentication(method: String)
    case tlsNotSupportedByServer
    case transportError(reason: String)
    case timedOut
    case protocolError(reason: String)
    case server(PostgresServerError)
    case poolExhausted(maxConnections: Int)
    case allConnectionsDown
    case subscriptionLimitReached(limit: Int)
    case poolShutdown
    case poolHasNoEndpoints
    case columnIndexOutOfRange(index: Int, columnCount: Int)
    case columnNameNotFound(name: String)
    case columnIsNull(column: String)
    case typeDecodingFailed(type: String, reason: String)
    case parameterCountMismatch(expected: Int, provided: Int)
    case jsonEncodingFailed(typeName: String, reason: String)
    case jsonDecodingFailed(typeName: String, reason: String)
    case utf8DecodingFailed
    case cancelled
    case noCurrentClient
}

extension PostgresError: CustomStringConvertible {

    public var description: String {
        switch self {
        case .connectionClosed: "the connection was closed before the request completed"
        case .connectFailed(let reason): "failed to open a connection: \(reason)"
        case .handshakeFailed(let reason): "PostgreSQL startup handshake failed: \(reason)"
        case .authenticationFailed(let reason): "PostgreSQL authentication failed: \(reason)"
        case .unsupportedAuthentication(let method): "the server requested an unsupported authentication method: \(method)"
        case .tlsNotSupportedByServer: "TLS was required but the server does not support it"
        case .transportError(let reason): "transport error: \(reason)"
        case .timedOut: "the request timed out before a response arrived"
        case .protocolError(let reason): "PostgreSQL wire-protocol error: \(reason)"
        case .server(let error): "PostgreSQL server error \(error.sqlState): \(error.message)"
        case .poolExhausted(let maxConnections): "no connection became available within the timeout while the pool was saturated at \(maxConnections) connections"
        case .allConnectionsDown: "every pooled connection is down; the pool is reconnecting in the background. Retry shortly"
        case .subscriptionLimitReached(let limit): "the subscription limit of \(limit) has been reached; close a subscription before opening another"
        case .poolShutdown: "the connection pool has been shut down"
        case .poolHasNoEndpoints: "the connection pool was configured with no endpoints"
        case .columnIndexOutOfRange(let index, let columnCount): "column index \(index) is out of range for a row with \(columnCount) columns"
        case .columnNameNotFound(let name): "no column named \(name) in the row"
        case .columnIsNull(let column): "column \(column) is SQL NULL; decode it with a nullable form instead"
        case .typeDecodingFailed(let type, let reason): "failed to decode value as \(type): \(reason)"
        case .parameterCountMismatch(let expected, let provided): "the query expects \(expected) bound parameters but \(provided) were provided"
        case .jsonEncodingFailed(let typeName, let reason): "JSON encoding of \(typeName) failed: \(reason)"
        case .jsonDecodingFailed(let typeName, let reason): "JSON decoding of \(typeName) failed: \(reason)"
        case .utf8DecodingFailed: "the value payload was not valid UTF-8"
        case .cancelled: "the request was cancelled"
        case .noCurrentClient: "no PostgreSQL client is bound to the current task; bind one with Postgres.withCurrent(_:_:) before calling Postgres.current()"
        }
    }
}
