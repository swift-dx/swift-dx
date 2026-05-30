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

// Typed error enum for the raw POSIX-socket ClickHouse transport.
// Six cases cover every failure mode the raw stack surfaces: socket
// open, in-flight I/O, server-side disconnect, wire protocol violation,
// server-side query exception, and resilience-layer reconnect exhaustion.
// Adding a case is a SemVer-breaking change because downstream exhaustive
// switches will stop compiling — that is intentional, see SwiftDX's
// architecture rule on typed errors.
public enum RawClickHouseError: Error, Sendable, Equatable, CustomStringConvertible {

    case connectionFailed(reason: String)
    case socketIOFailed(errno: Int32, syscall: String)
    case unexpectedEOF(bytesExpected: Int)
    case protocolError(stage: String, message: String)
    case queryFailed(serverException: String)
    case reconnectExhausted(attempts: Int)

    public var description: String {
        switch self {
        case .connectionFailed(let reason):
            "connection failed: \(reason)"
        case .socketIOFailed(let errno, let syscall):
            "socket I/O failed: \(syscall) errno=\(errno)"
        case .unexpectedEOF(let bytesExpected):
            "unexpected EOF, expected \(bytesExpected) more bytes"
        case .protocolError(let stage, let message):
            "protocol error at \(stage): \(message)"
        case .queryFailed(let serverException):
            "query failed: \(serverException)"
        case .reconnectExhausted(let attempts):
            "reconnect exhausted after \(attempts) attempts"
        }
    }
}
