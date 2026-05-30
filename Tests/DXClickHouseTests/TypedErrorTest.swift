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

import DXClickHouse
import Testing

@Suite("ClickHouseError typed-throws compliance")
struct ClickHouseErrorTypedThrowsTest {

    private static let sampleException = ClickHouseServerException(
        code: 42,
        name: "Syntax",
        message: "bad",
        stackTrace: "trace"
    )

    // Exhaustive switch over every case. The whole point of the typed
    // error contract is that adding a case downstream becomes a
    // compile-time break — this test pins that contract by asserting
    // an exhaustive match across all seven cases. Reordering or
    // removing a case here must come with an upstream change to the
    // enum.
    @Test("exhaustive switch over ClickHouseError compiles cleanly")
    func exhaustiveSwitchCompiles() {
        let samples: [ClickHouseError] = [
            .connectionFailed(reason: "test"),
            .socketIOFailed(errno: 32, syscall: "send"),
            .unexpectedEOF(bytesExpected: 16),
            .protocolError(stage: "uvarint", message: "overflow"),
            .queryFailed(serverException: Self.sampleException),
            .reconnectExhausted(attempts: 5),
            .endpointsExhausted(failures: [ClickHouseEndpointFailure(host: "h", port: 9000, reason: "refused")]),
        ]
        var observed: [String] = []
        for error in samples {
            switch error {
            case .connectionFailed(let reason):
                observed.append("connectionFailed:\(reason)")
            case .socketIOFailed(let errno, let syscall):
                observed.append("socketIOFailed:\(syscall)/\(errno)")
            case .unexpectedEOF(let bytesExpected):
                observed.append("unexpectedEOF:\(bytesExpected)")
            case .protocolError(let stage, let message):
                observed.append("protocolError:\(stage)/\(message)")
            case .queryFailed(let serverException):
                observed.append("queryFailed:\(serverException.code)/\(serverException.name)")
            case .reconnectExhausted(let attempts):
                observed.append("reconnectExhausted:\(attempts)")
            case .endpointsExhausted(let failures):
                observed.append("endpointsExhausted:\(failures.count)")
            }
        }
        #expect(observed.count == 7)
        #expect(observed[0] == "connectionFailed:test")
        #expect(observed[1] == "socketIOFailed:send/32")
        #expect(observed[2] == "unexpectedEOF:16")
        #expect(observed[3] == "protocolError:uvarint/overflow")
        #expect(observed[4] == "queryFailed:42/Syntax")
        #expect(observed[5] == "reconnectExhausted:5")
        #expect(observed[6] == "endpointsExhausted:1")
    }

    @Test("ClickHouseError is Equatable per case")
    func equatableContract() {
        let exceptionA = ClickHouseServerException(code: 1, name: "n", message: "m")
        let exceptionB = ClickHouseServerException(code: 2, name: "n", message: "m")
        #expect(ClickHouseError.connectionFailed(reason: "x") == ClickHouseError.connectionFailed(reason: "x"))
        #expect(ClickHouseError.connectionFailed(reason: "x") != ClickHouseError.connectionFailed(reason: "y"))
        #expect(ClickHouseError.socketIOFailed(errno: 32, syscall: "send") == ClickHouseError.socketIOFailed(errno: 32, syscall: "send"))
        #expect(ClickHouseError.socketIOFailed(errno: 32, syscall: "send") != ClickHouseError.socketIOFailed(errno: 104, syscall: "recv"))
        #expect(ClickHouseError.unexpectedEOF(bytesExpected: 16) != ClickHouseError.unexpectedEOF(bytesExpected: 32))
        #expect(ClickHouseError.protocolError(stage: "a", message: "b") != ClickHouseError.protocolError(stage: "a", message: "c"))
        #expect(ClickHouseError.queryFailed(serverException: exceptionA) != ClickHouseError.queryFailed(serverException: exceptionB))
        #expect(ClickHouseError.reconnectExhausted(attempts: 5) != ClickHouseError.reconnectExhausted(attempts: 3))
    }

    @Test("ClickHouseError CustomStringConvertible carries case data")
    func descriptionCarriesData() {
        #expect(ClickHouseError.connectionFailed(reason: "DNS").description.contains("DNS"))
        #expect(ClickHouseError.socketIOFailed(errno: 32, syscall: "send").description.contains("send"))
        #expect(ClickHouseError.socketIOFailed(errno: 32, syscall: "send").description.contains("32"))
        #expect(ClickHouseError.unexpectedEOF(bytesExpected: 99).description.contains("99"))
        #expect(ClickHouseError.protocolError(stage: "block info", message: "bad field").description.contains("block info"))
        #expect(ClickHouseError.protocolError(stage: "block info", message: "bad field").description.contains("bad field"))
        #expect(ClickHouseError.queryFailed(serverException: Self.sampleException).description.contains("code=42"))
        #expect(ClickHouseError.queryFailed(serverException: Self.sampleException).description.contains("Syntax"))
        #expect(ClickHouseError.reconnectExhausted(attempts: 7).description.contains("7"))
        let exhausted = ClickHouseError.endpointsExhausted(failures: [
            ClickHouseEndpointFailure(host: "host-x", port: 9000, reason: "refused"),
        ])
        #expect(exhausted.description.contains("host-x"))
    }

    // Reconnect to a port nothing is listening on. With a default
    // policy of 5 attempts, the connection construction itself fails
    // on the very first `openSocket` call (no socket exists), so we
    // see `.connectionFailed` rather than `.reconnectExhausted` —
    // reconnect is only triggered by transient I/O failures on an
    // already-open socket.
    @Test("Connect to an unreachable port surfaces .connectionFailed")
    func connectFailureSurfacesTypedError() {
        var observed: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try ClickHouseConnection(host: "127.0.0.1", port: 1)
            Issue.record("expected connection failure")
        } catch let error {
            observed = error
        }
        switch observed {
        case .connectionFailed:
            break
        case .socketIOFailed, .unexpectedEOF, .protocolError, .queryFailed, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected .connectionFailed, got \(observed)")
        }
    }

    @Test("ReconnectionPolicy.default has 5 attempts, 100ms initial, 5s cap")
    func defaultPolicyShape() {
        let policy = ReconnectionPolicy.default
        #expect(policy.maxAttempts == 5)
        #expect(policy.initialBackoff == .milliseconds(100))
        #expect(policy.maxBackoff == .seconds(5))
    }

    @Test("ReconnectionPolicy.disabled has 0 attempts")
    func disabledPolicyShape() {
        #expect(ReconnectionPolicy.disabled.maxAttempts == 0)
    }
}
