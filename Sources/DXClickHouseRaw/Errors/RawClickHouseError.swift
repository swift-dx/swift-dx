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
// Every failure path the raw stack can surface has a named case; adding
// a case is a SemVer-breaking change because downstream exhaustive
// switches will stop compiling. That is intentional, see SwiftDX's
// architecture rule on typed errors.
//
// Case roles:
//   * connectionFailed       — socket open / DNS / handshake refused
//   * socketIOFailed         — in-flight send/recv syscall returned -1
//   * unexpectedEOF          — recv returned 0 mid-stream
//   * protocolError          — wire bytes violate the framing contract
//   * queryFailed            — server returned a fully-decoded Exception
//                              packet. The payload carries the original
//                              server-side code, name, message, and
//                              optional stack trace; consumers route on
//                              `serverException.code`.
//   * reconnectExhausted     — connection-layer retry budget hit zero
//   * endpointsExhausted     — pool tried every configured endpoint and
//                              every connect attempt failed. Aggregated
//                              per-endpoint failure reasons attached.
public enum RawClickHouseError: Error, Sendable, Equatable, CustomStringConvertible {

    case connectionFailed(reason: String)
    case socketIOFailed(errno: Int32, syscall: String)
    case unexpectedEOF(bytesExpected: Int)
    case protocolError(stage: String, message: String)
    case queryFailed(serverException: RawClickHouseServerException)
    case reconnectExhausted(attempts: Int)
    case endpointsExhausted(failures: [RawEndpointFailure])

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
            "query failed: \(serverException.description)"
        case .reconnectExhausted(let attempts):
            "reconnect exhausted after \(attempts) attempts"
        case .endpointsExhausted(let failures):
            "every endpoint failed: \(failures.map { $0.description }.joined(separator: "; "))"
        }
    }
}

// Decoded server-side ClickHouse exception. Carries the structured
// contents of a Server Exception packet (type=2) so callers can route
// on the numeric `code` rather than a textual blob. `nested` holds a
// recursively-decoded inner exception when the server attached one
// (the wire format chains exceptions via a `has_nested` flag).
public struct RawClickHouseServerException: Sendable, Equatable, CustomStringConvertible {

    public let code: Int32
    public let name: String
    public let message: String
    public let stackTrace: String
    public let nested: [RawClickHouseServerException]

    public init(
        code: Int32,
        name: String,
        message: String,
        stackTrace: String = "",
        nested: [RawClickHouseServerException] = []
    ) {
        self.code = code
        self.name = name
        self.message = message
        self.stackTrace = stackTrace
        self.nested = nested
    }

    public var description: String {
        if nested.isEmpty {
            return "code=\(code) name=\(name) message=\(message)"
        }
        let nestedDescription = nested.map { $0.description }.joined(separator: " -> ")
        return "code=\(code) name=\(name) message=\(message) nested=[\(nestedDescription)]"
    }
}

// Aggregated per-endpoint failure record, returned inside
// `RawClickHouseError.endpointsExhausted` when the pool exhausts its
// configured endpoint list. Callers can iterate to surface a precise
// per-host diagnostic.
public struct RawEndpointFailure: Sendable, Equatable, CustomStringConvertible {

    public let host: String
    public let port: Int
    public let reason: String

    public init(host: String, port: Int, reason: String) {
        self.host = host
        self.port = port
        self.reason = reason
    }

    public var description: String {
        "\(host):\(port) -> \(reason)"
    }
}
